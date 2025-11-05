#!/bin/bash

PID="$1"

# Encuentra el ID de la ventana asociado con el PID
WINDOW_ID=$(wmctrl -lp | awk -v pid="$PID" '$3==pid {print $1}')

if [ -z "$WINDOW_ID" ]; then
    echo "No se encontró una ventana para el PID $PID"
    exit 1
fi

# Obtener la geometría de la ventana usando xwininfo
GEOMETRY=$(xwininfo -id "$WINDOW_ID" | awk '/Absolute/ {print $4} /Width/ {width=$2} /Height/ {height=$2} END {print width"x"height}')

# Formatear la salida
if [ -z "$GEOMETRY" ]; then
    echo "No se pudo obtener la geometría para la ventana con ID $WINDOW_ID"
    exit 1
else
    # GEOMETRY contiene las coordenadas x, y, ancho y alto separados por espacios
    read -r X Y WIDTH HEIGHT <<< "$GEOMETRY"
    echo "${WIDTH}x${HEIGHT}+${X}+${Y}"
fi
