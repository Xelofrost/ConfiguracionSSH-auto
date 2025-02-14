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