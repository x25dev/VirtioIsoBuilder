# VirtioIsoBuilder

I build this script to make my own life easier; all-in-one Windows (Server) Installer .iso files to use on KVM based hosts (e.g., Proxmox) using only a single .iso at a time; This PowerShell Script builds bootable Windows (Server) installer .iso files with the Virtio drivers included. It uses my own preferences as default.

In the past, I used the CLI to slipstream my Windows installer .iso, but now it can be done with the click of a button.\
This 0.2 version includes a GUI + automated download of Windows using [UUP dump JSON API](https://uupdump.net/), and the option to download a Windows Evaluation version using the [Windows Evaluation Center](https://www.microsoft.com/en-us/evalcenter) (when these versions are not available via [UUP dump JSON API](https://uupdump.net/).

This script requires PowerShell >5.1 and elevated rights in order to use Aria2 and Dism.

# How to use:

1) Pick the Windows version, it's source, Build, Language and Edition OR select local .iso file;
2) Select the Virtio driver for Windows version OR select local .iso file that contains these files;
3) Select work- and optional output folder.

The script will get all files and generates a single .iso file.

![description](https://i.postimg.cc/qRyJj63R/Virtio-Iso-Builder0-1.png)

# Options

* Default, the following Virtio drivers are included:

viostor 
vioscsi    
NetKVM    
Balloon   
vioserial

* "All drivers" will also include the following Virtio drivers:

fwcfg
pvpanic
qemufwcfg
qemupciserial
qxldod
smbus
sriov
viofs
viogpudo
vioinput
viomem
viorng    
viosock    

* QEMU Guest Agent:

Will automatically install the QEMU Agent after installation for use on e.g., Proxmox 

* Sources:
  
[UUP dump JSON API](https://uupdump.net/)
[fedorapeople.org](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/)
[Windows Evaluation Center](https://www.microsoft.com/en-us/evalcenter)

# Next release will include:
- Option to add a "Custom Drivers" folder (e.g., Wifi drivers for laptop)
- Option to de-select Virtio drivers (when using "Custom Drivers" option)
- Option to add "autounattend.xml" file (add custom Out-Of-Box Experience (OOBE)) 
- Option to add "pid.txt" file (e.g., use your Windows 11 Professional Retail license Key instead of current Windows 11 Home OEM one)

# Important! 

Use this script at your own risk. While it has been written with care and security in mind, the author assumes no responsibility or liability for any errors, bugs, system failures, data loss, or damages arising from its use.
