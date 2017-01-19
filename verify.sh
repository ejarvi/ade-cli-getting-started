# independently inspect disk layout and encryption status 
lsblk 
mount
while read guid; do 
        sudo cryptsetup status $guid  
done < <(mount |  grep -o '[a-fA-F0-9]\{8\}-[a-fA-F0-9-]\{5\}\{3\}[a-fA-F0-9]\{12\}')
