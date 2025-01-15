#!/bin/bash

# Verificar si se ejecuta como root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta este script como root o con sudo."
  exit 1
fi
# Actualizamos el sistema para evitar incompatibilidades
apt update
apt upgrade -y

# Instlamos y creamos un TimeShift para poder reiniciar en caso de ser necesario
apt install timeshift -y
create snapshot
timeshift --create --comment "Inicio de instalación/Initial Setup"

# Permitir el puerto 777/tcp en UFW
echo "Permitiendo el puerto 777/tcp en el firewall UFW..."
ufw allow 777/tcp
ufw enable
ufw reload

# Cambiar el puerto SSH al 777
echo "Cambiando el puerto SSH a 777..."
sed -i '/^#\?Port [0-9]*/c\Port 777' /etc/ssh/sshd_config

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

# Instalar Cowrie y configurar la redirección del puerto 22 al 2222
echo "Instalando Cowrie y configurando la redirección del puerto 22 al 2222..."
apt update && apt install -y git python3-venv python3-dev libssl-dev libffi-dev build-essential
adduser --disabled-password cowrie
su - cowrie -c "git clone https://github.com/cowrie/cowrie /home/cowrie/cowrie"
su - cowrie -c "cd /home/cowrie/cowrie && python3 -m venv cowrie-env && source cowrie-env/bin/activate && pip install --upgrade pip && pip install -r requirements.txt"
ufw allow 2222/tcp
ufw reload
iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
iptables-save > /etc/iptables/rules.v4
su - cowrie -c "/home/cowrie/cowrie/bin/cowrie start"

# Finalización
echo "El puerto SSH ha sido cambiado a 777, y se han instalado y configurado fail2ban, Snort2 y Cowrie."
echo "Recuerda verificar las configuraciones adicionales si es necesario."