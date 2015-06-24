#!/bin/bash
#
# Script file for downloading and building an single file
# linux for a Baytrail Intel Bootloader
#

# defines
BB=busybox-1.21.1
LINUX=linux-3.12

# Only get BusyBox when it is not here
if [ ! -d "busybox" ]; then
	if [ ! -f "$BB".tar.bz2 ]; then
		echo "get busybox"
		wget http://busybox.net/downloads/"$BB".tar.bz2
	fi 
	tar jxvf "$BB".tar.bz2
	mv "$BB" busybox
fi

if [ ! -d "linux" ]; then
	if [ ! -f "$LINUX".tar.xz ]; then
		echo "get \"$LINUX\".tar.xz"
		wget https://www.kernel.org/pub/linux/kernel/v3.x/"$LINUX".tar.xz
	fi
	tar Jxvf "$LINUX".tar.xz
	mv "$LINUX" linux
fi

echo "remove the config files. This may fail..."
rm busybox/.config
rm linux/.config

echo "symlink config files to the actual files"
ln -s ../config/config_linux linux/.config
ln -s ../config/config_busybox busybox/.config

echo "Going to build the busybox binary... The log file can be found at busybox_build.log"
cd busybox
make -j8 > ../busybox_build.log 2>&1

echo "Going to build the Linux kernel... The log file can be found at linux_build.log"
cd ../linux
make -j8 > ../linux_build.log 2>&1

echo "Continue to install Simple Linux to drive? (This is for Intel Bootloader)"
select yn in "Yes" "No"; do
  case $yn in
    Yes ) 

echo "Create a bootalble disk on /dev/sdb"
cp arch/x86/boot/bzImage ../
cd ..
chmod +x journal.rb
sudo ./journal.rb -c dual_kernel.xml -d /dev/sdb
break ;;
    No ) exit;;
  esac
done
