#!/bin/bash
for file in $(find /quay-registry -name "*.sh"); do
  echo "Fixing $file"
  sed -i 's/\r$//' "$file"
  chmod +x "$file"
done