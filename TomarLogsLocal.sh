#!/bin/bash

# Pedir al usuario la IP del servidor remoto
read -p "Introduce la IP del servidor remoto: " SSH_HOST

# Pedir el nombre de usuario del servidor remoto
read -p "Introduce el nombre de usuario del servidor remoto: " SSH_USER

# Ruta de los logs en el servidor remoto
read -p "Introduce la ruta de los logs en el servidor remoto: " SSH_PATH

# Ruta local donde se guardarán los logs
LOCAL_PATH="./logs_ssh"    # Ruta local donde se guardarán los logs

# Crear la carpeta local si no existe
if [ ! -d "$LOCAL_PATH" ]; then
  echo "Creando la carpeta local '$LOCAL_PATH'..."
  mkdir -p "$LOCAL_PATH"
fi

# Comando SCP para copiar los logs desde el servidor remoto usando el puerto 777
echo "Copiando los logs desde el servidor remoto..."
scp -P 777 "$SSH_USER@$SSH_HOST:$SSH_PATH/*.log" "$LOCAL_PATH"

# Comprobar si el comando SCP fue exitoso
if [ $? -eq 0 ]; then
  echo "Los logs se han copiado correctamente en '$LOCAL_PATH'."
else
  echo "Hubo un error al copiar los logs."
  exit 1
fi
