#!/bin/bash

# ===================================================================
#                      CONFIGURACIÓN INICIAL
# ===================================================================
# Todas las preguntas al usuario se hacen aquí al principio

# Solicitar datos de conexión
read -p "IP/Nombre del servidor remoto: " remote_host
read -p "Usuario SSH en el servidor remoto: " remote_user

# Validar puerto SSH
while true; do
    read -p "Puerto SSH personalizado (ej. 777): " ssh_port
    [[ "$ssh_port" =~ ^[0-9]+$ ]] && [ "$ssh_port" -ge 1 -a "$ssh_port" -le 65535 ] && break
    echo "Error: Introduce un puerto válido (1-65535)."
done

# Datos nuevo usuario
read -p "Nombre del nuevo usuario: " new_user
read -sp "Contraseña para $new_user: " new_user_password
echo

# ===================================================================
#                   CONFIGURACIÓN AUTOMÁTICA SSH
# ===================================================================

remote_port=22  # Puerto temporal

# Generar clave SSH si no existe
[ ! -f ~/.ssh/id_rsa.pub ] && ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q

# Copiar clave pública
echo -e "\nCopiando clave SSH..."
ssh-copy-id -p 22 -i ~/.ssh/id_rsa.pub "$remote_user"@"$remote_host" || {
    echo -e "\nERROR: Fallo al copiar clave. Verifica:"
    echo -e "- Acceso al servidor $remote_host"
    echo -e "- Credenciales de $remote_user"
    exit 1
}

# Limpiar known_hosts
ssh-keygen -R "$remote_host" -f ~/.ssh/known_hosts -q

# ===================================================================
#                  PREPARACIÓN SCRIPT REMOTO
# ===================================================================

script_temp="setup_remote.sh"

# Generar script remoto con HERE DOCUMENT
cat << EOF > "$script_temp"
#!/bin/bash
# --------------------------------------------
# Update, upgrade y timeshift, solo por si acaso
# --------------------------------------------

apt update


apt install timeshift -y
timeshift --create --comment "Inicio de instalación/Initial Setup"

# --------------------------------------------
# Creación de usuario y permisos
# --------------------------------------------
echo "Creando usuario $new_user..."
adduser --disabled-password --gecos "" "$new_user" >/dev/null
echo "$new_user:$new_user_password" | chpasswd
usermod -aG sudo "$new_user"

# Configurar SSH del usuario
cp -r .ssh /home/$new_user/.ssh/
chown -R $new_user:$new_user /home/$new_user/.ssh
chmod 700 /home/$new_user/.ssh
chmod 600 /home/$new_user/.ssh/authorized_keys

# --------------------------------------------
# Hardening SSH
# --------------------------------------------
sed -i "s/^#*Port .*/Port $ssh_port/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# --------------------------------------------
# Configuración UFW
# --------------------------------------------
ufw allow $ssh_port/tcp
ufw allow 22/tcp
ufw allow 1514/tcp
ufw allow 1515/tcp
ufw enable
ufw reload

# --------------------------------------------
# Instalaciones opcionales (con TTY)
# --------------------------------------------
ask_confirmation() {
    while true; do
        read -p "\$1 (Y/N): " response  # <- \$1 escapado
        case "\$response" in            # <- \$response escapado
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Responde Y/N.";;
        esac
    done
}
# Upgrade
if ask_confirmation "¿Tirar upgrade?"; then
    apt upgrade -y
fi
# Fail2ban
if ask_confirmation "¿Instalar fail2ban?"; then
    apt install -y fail2ban
    cat << 'EOL' > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 30m
maxretry = 3

[sshd]
enabled = true
port = $ssh_port
EOL
    systemctl restart fail2ban
fi

# Snort2
if ask_confirmation "¿Instalar Snort?"; then
    apt install -y snort

    # Nueva sección de reglas
    echo -e "\nConfiguración de reglas de Snort:"
    if ask_confirmation "¿Desea usar reglas predeterminadas?"; then
         echo "Añadiendo reglas básicas de Snort..."
         cat << 'EOL' >> /etc/snort/rules/local.rules
alert tcp any any -> any 80 (msg:"SQL Injection Detected"; content:"%27%20OR%20"; nocase; http_uri; sid:1000001;)
alert tcp any any -> any 80 (msg:"XSS Attempt"; content:"<script>"; http_client_body; sid:1000002;)
alert ip any any -> any any (msg:"Port Scan Attempt"; detection_filter: track by_src, count 5, seconds 10; sid:1000003;)
alert tcp any any -> any 21 (msg:"FTP Buffer Overflow Attempt"; content:"|90 90 90 E8 C0 FF FF FF|"; sid:1000004;)
alert tcp any any -> any 445 (msg:"EternalBlue Exploit Attempt"; content:"|FF|SMB|73|"; depth:5; sid:1000005;)
alert tcp any any -> any 443 (msg:"Zeus C2 Traffic"; content:"/config.bin"; http_uri; sid:1000006;)
alert tcp any any -> any 443 (msg:"Heartbleed Exploit"; content:"|18 03 00 00 03|"; offset:9; sid:1000007;)
alert udp any any -> any 53 (msg:"DNS Tunneling Attempt"; content:"|01|"; depth:1; sid:1000008;)
alert tcp any any -> any 80 (msg:"Directory Traversal Attempt"; content:"../"; http_uri; sid:1000009;)
alert tcp any any -> any any (msg:"SYN Flood"; flags:S; detection_filter: track by_dst, count 100, seconds 1; sid:1000010;)
EOL
         systemctl restart snort
         echo -e "\n\e[1;32m[+] Reglas aplicadas. Snort reiniciado.\e[0m"
         echo -e "Ver logs en: \e[1;34m/var/log/snort/alert_fast\e[0m"
    else
         echo -e "\n\e[1;33m[!] Configura tus reglas en:\e[0m /etc/snort/rules/local.rules"
         echo -e "Ver logs en: \e[1;34m/var/log/snort/alert_fast\e[0m"
         echo -e "Reinicia después de editar: \e[1;36msystemctl restart snort\e[0m"
    fi
fi


# Cowrie
if ask_confirmation "¿Instalar Cowrie?"; then
    apt install -y git python3-venv python3-dev libssl-dev libffi-dev build-essential
    adduser --disabled-password --gecos "" cowrie
    su - cowrie -c "git clone https://github.com/cowrie/cowrie.git /home/cowrie/cowrie"
    su - cowrie -c "cd /home/cowrie/cowrie && python3 -m venv cowrie-env"
    su - cowrie -c "cd /home/cowrie/cowrie && source cowrie-env/bin/activate && pip install --upgrade pip && pip install -r requirements.txt"
    ufw allow 2222/tcp
    ufw reload
    iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
    su - cowrie -c "/home/cowrie/cowrie/bin/cowrie start"
fi

# --------------------------------------------
# Finalización
# --------------------------------------------
systemctl restart ssh
echo "¡Configuración completada! Puerto SSH: $ssh_port"
EOF

# ===================================================================
#              EJECUCIÓN REMOTA CON INTERACTIVIDAD
# ===================================================================

echo -e "\nIniciando configuración en $remote_host..."
scp -o "StrictHostKeyChecking=no" -P "$remote_port" "$script_temp" "$remote_user@$remote_host:/tmp/" && \
ssh -tt -o "StrictHostKeyChecking=no" -p "$remote_port" "$remote_user@$remote_host" \
    "bash /tmp/$script_temp && rm /tmp/$script_temp"

# Limpieza
rm -f "$script_temp"

echo -e "\n¡Todo listo! Acceso recomendado:"
echo -e "ssh -p $ssh_port $new_user@$remote_host"