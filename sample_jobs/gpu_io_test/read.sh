
#!/bin/bash

echo "copying 1x 20GB file..."
for (( i=0; i<1 ; i++ )); do sfx=$(printf %02d $i) ; dd if=/runtime/file20GB_$sfx of=/output/file20GB_$sfx bs=1000000000 count=20 ; done
echo "copying 1x 5GB files..."
dd if=/runtime/file5GB of=/output/file5GB  bs=10000000 count=500
echo "done."
