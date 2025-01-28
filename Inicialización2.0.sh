#!/bin/bash

# Pedir la IP del servidor remoto
read -p "Introduce la IP o nombre de dominio del servidor remoto: " remote_host

# Pedir las credenciales del usuario remoto
read -p "Introduce el nombre del usuario en el servidor remoto: " remote_user

# Usar el puerto SSH por defecto 22
remote_port=22

# Verificar si ya existe una clave pública SSH
if [ ! -f /home/kali/.ssh/id_rsa.pub ]; then
  echo "No se encontró una clave pública SSH. Creando una nueva..."
  ssh-keygen -t rsa -b 4096 -f /home/kali/.ssh/id_rsa -N ""
fi

# Copiar la clave pública al servidor remoto
if ! ssh-copy-id -p "$remote_port" -i /home/kali/.ssh/id_rsa.pub "$remote_user@$remote_host"; then
  echo "Error al copiar la clave pública. Asegúrate de que la clave esté configurada correctamente."
  exit 1
fi

# Pedir el nombre y la contraseña del nuevo usuario
read -p "Introduce el nombre del nuevo usuario: " new_user
read -sp "Introduce la contraseña para el nuevo usuario: " new_user_password
echo

# Limpiar la clave del host remoto del archivo known_hosts
echo "Limpiando la clave del host remoto obsoleta en known_hosts..."
ssh-keygen -R "$remote_host" -f /root/.ssh/known_hosts

# Ruta del script local que quieres ejecutar en el servidor remoto
script_file="setup_server.sh"

# Crear un script temporal para ejecutar en el servidor remoto
cat << EOF > $script_file
#!/bin/bash

# Verificar si se ejecuta como root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta este script como root o con sudo."
  exit 1
fi

# Actualizamos el sistema para evitar incompatibilidades
apt update
apt upgrade -y

# Instalamos y creamos un TimeShift para poder reiniciar en caso de ser necesario
apt install timeshift -y
timeshift --create --comment "Inicio de instalación/Initial Setup"

# Permitir el puerto 777/tcp en UFW
echo "Permitiendo el puerto 777/tcp en el firewall UFW..."
ufw allow 777/tcp
ufw enable
ufw reload

# Permitir los puertos 1514 y 1515/tcp para Wazuh
echo "Permitiendo los puertos 1514 y 1515/tcp en el firewall UFW para Wazuh..."
ufw allow 1514/tcp
ufw allow 1515/tcp
ufw reload

# Cambiar el puerto SSH al 777
echo "Cambiando el puerto SSH a 777..."
sed -i '/^#\?Port [0-9]*/c\Port 777' /etc/ssh/sshd_config

# Denegar acceso SSH para root
echo "Denegando acceso SSH al usuario root..."
sed -i '/^#\?PermitRootLogin/c\PermitRootLogin no' /etc/ssh/sshd_config

# Configurar SSH para no pedir contraseña y usar solo autenticación con clave pública
echo "Habilitando autenticación solo con clave pública en SSH..."
sed -i '/^#\?PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
sed -i '/^#\?PubkeyAuthentication/c\PubkeyAuthentication yes' /etc/ssh/sshd_config

# Reiniciar el servicio SSH para aplicar los cambios
echo "Reiniciando el servicio SSH..."
systemctl enable ssh
systemctl restart ssh

# Instalar fail2ban
echo "Instalando fail2ban..."
apt update && apt install -y fail2ban

# Configuración básica de fail2ban (opcional)
cat <<EOL > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = 777
EOL

# Reiniciar fail2ban para aplicar la configuración
echo "Reiniciando fail2ban..."
systemctl restart fail2ban

# Instalar snort2
echo "Instalando Snort2..."
apt install -y snort

# Añadir el usuario proporcionado y añadirlo al grupo sudoers
echo "Añadiendo el usuario $new_user..."
adduser --disabled-password --gecos "" "$new_user"
echo "$new_user:$new_user_password" | chpasswd
usermod -aG sudo "$new_user"

# Configurar la carpeta .ssh para el nuevo usuario
echo "Configurando la carpeta .ssh para el usuario $new_user..."
mkdir -p "/home/$new_user/.ssh"
cp -r .ssh "/home/$new_user"
chown -R "$new_user:$new_user" "/home/$new_user/.ssh"
chmod 700 "/home/$new_user/.ssh"
chmod 600 "/home/$new_user/.ssh/authorized_keys"

# Instalar Cowrie y configurar la redirección del puerto 22 al 2222
echo "Instalando Cowrie y configurando la redirección del puerto 22 al 2222..."
apt update && apt install -y git python3-venv python3-dev libssl-dev libffi-dev build-essential
adduser --disabled-password --gecos "" cowrie
su - cowrie -c "git clone https://github.com/cowrie/cowrie /home/cowrie/cowrie"
su - cowrie -c "cd /home/cowrie/cowrie && python3 -m venv cowrie-env && source cowrie-env/bin/activate && pip install --upgrade pip && pip install -r requirements.txt"
ufw allow 2222/tcp
ufw reload
iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
su - cowrie -c "/home/cowrie/cowrie/bin/cowrie start"

# Finalización
echo "El puerto SSH ha sido cambiado a 777, y se han instalado y configurado fail2ban, Snort2 y Cowrie."
echo "Recuerda verificar las configuraciones adicionales si es necesario."

EOF

# Copiar el script temporal al servidor remoto y ejecutarlo
echo "Enviando y ejecutando el script en el servidor remoto..."

scp -P "$remote_port" $script_file "$remote_user@$remote_host:/tmp/setup_server.sh"
ssh -p "$remote_port" "$remote_user@$remote_host" 'bash /tmp/setup_server.sh && rm /tmp/setup_server.sh'

# Limpiar el script temporal en el host local
rm $script_file

echo "El script se ha ejecutado en el servidor remoto."
