#!/bin/sh
#
# Create all the busybox symbolic links
/bin/busybox echo "# Hello Linux Init"

/bin/busybox --install

# Create base directories
#[ -d /dev ] || mkdir -m 0755 /dev
[ -d /root ] || mkdir --mode=0700 /root
[ -d /sys ] || mkdir /sys
#[ -d /proc ] || mkdir /proc
[ -d /tmp ] || mkdir /tmp
mkdir -p /var/lock

echo "# Mount essential filesystems" 
# Mount essential filesystems
mount -t proc none /proc -onodev,noexec,nosuid
mount -t sysfs sysfs /sys

echo "# Create essential filesystem nodes"
# Create essential filesystem nodes
mknod /dev/zero c 1 5
mknod /dev/null c 1 3
mknod /dev/ptmx c 5 2

echo "echo \"/sbin/mdev\" > /proc/sys/kernel/hotplug"
echo "/sbin/mdev" > /proc/sys/kernel/hotplug

echo "Creatingdevices" 
/sbin/mdev -s
echo "Creatingdevices done" 
#exec /sbin/init
setsid sh -c 'exec sh </dev/ttyS0 >/dev/ttyS0 2>&1'
#/sbin/getty -L ttyS0 115200 vt100
#exec sh 
