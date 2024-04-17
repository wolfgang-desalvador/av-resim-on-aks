#!/bin/bash


echo "creating 1x 20GB files..."
for (( i=0; i<1 ; i++ )); do sfx=$(printf %02d $i) ; dd if=/dev/urandom of=/runtime/file20GB_$sfx bs=1000000000 count=20 ; done
echo "creating 1x 5GB file..."
dd if=/dev/urandom of=/runtime/file5GB bs=10000000 count=500
echo "creating 5x 10kB files..."
for (( i=0; i<5 ; i++ )); do sfx=$(printf %02d $i) ; dd if=/dev/urandom of=/runtime/file10kB_$sfx bs=10000 count=1 ; done
echo "creating 5x 10MB files..."
for (( i=0; i<5 ; i++ )); do sfx=$(printf %02d $i) ; dd if=/dev/urandom of=/runtime/file10MB_$sfx bs=10000000 count=1 ; done
echo "creating 2x 50MB files..."
for (( i=0; i<2 ; i++ )); do sfx=$(printf %02d $i) ; dd if=/dev/urandom of=/runtime/file50MB_$sfx bs=50000000 count=1 ; done