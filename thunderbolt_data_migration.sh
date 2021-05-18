#!/bin/zsh

# Written by Ryan Ball, Kurt Roberts and Chad Swarthout
# Originally obtained from: https://github.com/ryangball/thunderbolt-data-migration

# This variable can be used if you are testing the script
# Set to true while testing, the rsync will be bypassed and nothing permanent will done to this Mac
# Set to false when used in production
testing="false"  # (true|false)

# The full path of the log file
log="/var/log/alectrona.log"

# The main icon displayed in jamfHelper dialogs
icon="/Applications/Utilities/Migration Assistant.app/Contents/Resources/MigrateAsst.icns"

# The location to write the preferences for the launchdaemon.
preferences=/Library/Preferences/com.alectrona.scripts.migratorTool

# Create a password for the migrator user. Make sure to update both scripts.
migratorUserPassword="migrationisfun"

# Password Collection Messaging
PROMPT_TITLE="Password Needed For Migration"
FORGOT_PW_MESSAGE="You made five incorrect password attempts.
Please contact IT for assistance."

# The instructions that are shown in the first dialog to the user
instructions="You can now migrate your data from your old Mac.

1. Turn your old Mac off.

2. Connect your old Mac and new Mac together using the supplied Thunderbolt cable.

3. Power on your old Mac by normally pressing the power button WHILE holding the \"T\" button down for several seconds.

We will attempt to automatically detect your old Mac now..."

# Final instructions that will be shown before logging them out and making all the modifications
finalInstructions="You may now unplug your old Mac.

You're about to be logged out. Please do not disconnect power, shut down or suspend your machine until Please Wait has disappeared from the screen.

After Please Wait disappears from the screen, log in using your username and password from your old computer."

###### Variables below this point are not intended to be modified ######
scriptName=$(basename "$0")
jamfHelper=/Library/Application\ Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper

function writelog () {
    DATE=$(date +%Y-%m-%d\ %H:%M:%S)
    /bin/echo "${1}"
    /bin/echo "$DATE" " $1" >> "$log"
}

function finish () {
    writelog "======== Finished $scriptName ========"
		[[ -v jamfHelperPID ]] && { ps -p "$jamfHelperPID" > /dev/null && kill "$jamfHelperPID"; wait "$jamfHelperPID" 2>/dev/null }
    [[ -f /tmp/output.txt ]] && rm /tmp/output.txt
		[[ -v caffeinatepid ]] && kill "$caffeinatepid"
}

trap "finish" EXIT

function wait_for_gui () {
    # Wait for the Dock to determine the current user
    DOCK_STATUS=$(pgrep -x Dock)
    writelog "Waiting for Desktop..."

    while [[ "$DOCK_STATUS" == "" ]]; do
        writelog "Desktop is not loaded; waiting..."
        sleep 5
        DOCK_STATUS=$(pgrep -x Dock)
    done

    loggedInUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }')
		writelog "$loggedInUser is logged in and at the desktop; continuing."
}

function checkSecureTokenStatus () {
	# Alert and Exit if the current user lacks a secure token
	secureTokenStatus=$(sysadminctl -secureTokenStatus "$loggedInUser" 2>&1 | awk '{print$7}')
	if [[ $secureTokenStatus != "ENABLED" ]]; then
		writelog "User does not have a Secure Token. ($secureTokenStatus)"
		/bin/launchctl asuser "$loggedInUser" "$jamfHelper" -windowType utility \
							-title "User Data Transfer" -icon "$icon" -description "Error: Secure Token not detected. Please ensure you are not logged in with a management account. Contact IT for assistance." \
						 	-button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
		return 1
	fi
}

function perform_rsync () {
    writelog "Beginning rsync transfer..."
    "$jamfHelper" -windowType fs -title "" -icon "$icon" -heading "Please wait as we transfer your old data to your new Mac..." \
        -description "This might take awhile. You'll be prompted when complete." &>/dev/null &
    jamfHelperPID=$(/bin/echo $!)

    if [[ "$testing" != "true" ]]; then
			local stagingFolder="/Users/migratorTool-$oldUserName/"

			# make the folder
			mkdir -p $stagingFolder

	    # Perform the rsync
			/usr/bin/rsync -vau --progress --log-file="$log" "$oldUserHome/" "$stagingFolder"

    else
        writelog "Sleeping for 10 to simulate rsync..."
        sleep 10
    fi

    writelog "Finished rsync transfer."
    /usr/sbin/diskutil unmount "/Volumes/$tBoltVolume" &>/dev/null
    return 0
}

function calculate_space_requirements () {
    # Determine free space on this Mac
    freeOnNewMac=$(df -k / | tail -n +2 | awk '{print $4}')
    writelog "Free space on this Mac: $freeOnNewMac KB ($((freeOnNewMac/1024)) MB)"

    # Determine how much space the old home folder takes up
    spaceRequired=$(du -sck "$oldUserHome" | grep total | awk '{print $1}')
    writelog "Storage requirements for \"$oldUserHome\": $spaceRequired KB ($((spaceRequired/1024)) MB)"

    if [[ "$freeOnNewMac" -gt "$spaceRequired" ]]; then
        writelog "There is more than $spaceRequired KB available on this Mac; continuing."
        return 0
    else
        writelog "Not enough free space on this Mac; exiting."
        /bin/launchctl asuser "$loggedInUser" "$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "Your new Mac does not have enough free space to transfer your old data over. Please contact IT for assistance." -button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
        return 1
    fi
}

function manually_find_old_user () {
    # Determine all home folders on the old Mac
    oldUsersArray=()
    while IFS='' read -rA line; do oldUsersArray+=("$line"); done < <(/usr/bin/find "/Volumes/$tBoltVolume/Users" -maxdepth 1 -mindepth 1 -type d | awk -F'/' '{print $NF}' | grep -v Shared)

    # Exit if we didn't find any users
    if [[ ${#oldUsersArray[@]} -eq 0 ]]; then
        echo "No user home folders found in: /Volumes/$tBoltVolume/Users"
        /bin/launchctl asuser "$loggedInUser" "$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "Could not find any user home folders on the selected Thunderbolt volume. Please contact IT for assistance." -button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
        return 1
    fi

    # Show list of home folders so that the user can choose their old username
    # Something like cocoadialog would be preferred here as it has a dropdown, but it's got no Dark Mode :(
    # Heredocs cause some weird allignment issues
dialogOutput=$(/bin/launchctl asuser "$loggedInUser" /usr/bin/osascript <<EOF
    set ASlist to the paragraphs of "$(printf '%s\n' "${oldUsersArray[@]}")"
    choose from list ASlist with title "User Data Transfer" with prompt "Please choose your user account from your old Mac."
EOF
)

    # If the user chose one, store that as a variable, then see if we have enough space for the old data
    dialogOutput=$(grep -v "false" <<< "$dialogOutput")
    if [[ -n "$dialogOutput" ]]; then
        oldUserName="$dialogOutput"
        oldUserHome="/Volumes/$tBoltVolume/Users/$oldUserName"
        return 0
    else
        writelog "User cancelled; exiting."
        exit 0
    fi
}

function auto_find_old_user () {
    # Automatically loop through the user accounts on the old Mac, if one is found that matches the currently logged in user
    # we assume that is the user account to transfer data from. If a matching user is not found, let them manually chooose.
    while read -r line; do
        if [[ "$line" == "$loggedInUser" ]]; then
            writelog "Found a matching user ($line) on the chosen Thunderbolt volume; continuing."
            oldUserName="$line"
            oldUserHome="/Volumes/$tBoltVolume/Users/$line"
            return 0
        fi
    done < <(/usr/bin/find "/Volumes/$tBoltVolume/Users" -maxdepth 1 -mindepth 1 -type d | awk -F'/' '{print $NF}' | grep -v Shared)
    writelog "User with matching name on old Mac not found, moving on to manual selection."
    return 1
}

function choose_tbolt_volume () {
    # Figure out all connected Thunderbolt volumes
    tboltVolumesArray=()
    while IFS='' read -rA line; do
        while IFS='' read -rA line; do tboltVolumesArray+=("$line"); done < <(diskutil info "$line" | grep -B15 "Thunderbolt" | grep "Mount Point" | sed -n -e 's/^.*Volumes\///p')
    done < <(system_profiler SPStorageDataType | grep "BSD Name" | awk '{print $NF}' | sort -u)

    # Exit if we didn't find any connected Thunderbolt volumes
    if [[ ${#tboltVolumesArray[@]} -eq 0 ]]; then
        writelog "No Thunderbolt volumes connected at this time; exiting."
        /bin/launchctl asuser "$loggedInUser" "$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "There are no Thunderbolt volumes attached at this time.  Please contact IT for assistance." -button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
        exit 1
    fi

    # Allow the user to choose from a list of connected Thunderbolt volumes
    # Something like cocoadialog would be preferred here as it has a dropdown, but it's got no Dark Mode :(
    # Heredocs cause some weird allignment issues
dialogOutput=$(/bin/launchctl asuser "$loggedInUser" /usr/bin/osascript <<EOF
    set ASlist to the paragraphs of "$(printf '%s\n' "${tboltVolumesArray[@]}")"
    choose from list ASlist with title "User Data Transfer" with prompt "Please choose the Thunderbolt volume to transfer your data from."
EOF
)

    # If the user chose one, store that as a variable
    dialogOutput=$(grep -v "false" <<< "$dialogOutput")
    if [[ -n "$dialogOutput" ]]; then
        tBoltVolume="$dialogOutput"
        writelog "\"/Volumes/$tBoltVolume\" was selected by the user."
        return 0
    else
        writelog "User cancelled; exiting"
        exit 0
    fi
}

function detect_new_tbolt_volumes () {
    # Automaticaly detect a newly added Thunderbolt volume. The timer variable below can be modified to fit your environment
    # Most of this function (in the while loop) will loop every two seconds until the timer is done
    local timer="120"
    writelog "Waiting for Thunderbolt volumes..."
    while [[ "$timer" -gt "0" ]]; do
        # Determine status of jamfHelper
        if [[ "$(cat /tmp/output.txt)" == "0" ]]; then
            writelog "User cancelled; exiting."
            exit 0
        elif [[ "$(cat /tmp/output.txt)" == "2" ]]; then
            writelog "User chose to select a volume themselves."
            while [[ -z "$tBoltVolume" ]]; do
                return 1
            done
            return
        fi

        # Get the mounted volumes once (before)
        diskListBefore=$(/sbin/mount | grep '/dev/' | grep '/Volumes' | awk '{print $1}')
        diskCountBefore=$(echo -n "$diskListBefore" | grep -c '^')  # This method will produce a 0 if none, where as wc -l will not
        sleep 5

        # Get the mounted volumes 2 seconds later (after)
        diskListAfter=$(/sbin/mount | grep '/dev/' | grep '/Volumes' | awk '{print $1}')
        diskCountAfter=$(echo -n "$diskListAfter" | grep -c '^')  # This method will produce a 0 if none, where as wc -l will not

        # Determine if an additional volume has been mounted since our first check, if so we will check to see if it is Thunderbolt
        # If so, we move on to find the user accounts on the newly connected Thunderbolt volume
        # If not we ignore the newly connected non-Thunderbolt volume
        if [[ "$diskCountBefore" -lt "$diskCountAfter" ]]; then
            additional=$(/usr/bin/comm -13 <(echo "$diskListBefore") <(echo "$diskListAfter"))
            isTBolt=$(/usr/sbin/diskutil info "$additional" | grep -B15 "Thunderbolt" | grep "Mount Point" | sed -n -e 's/^.*Volumes\///p')
            if [[ -n "$isTBolt" ]]; then
                tBoltVolume="$isTBolt"
                writelog "\"/Volumes/$tBoltVolume\" has been detected as a new Thunderbolt volume; continuing."
                ps -p "$jamfHelperPID" > /dev/null && kill "$jamfHelperPID"; wait "$jamfHelperPID" 2>/dev/null
                return 0
            fi
        fi
        timer=$((timer-5))
    done
    # At this point the timer has run out, kill the background jamfHelper dialog and let the user know
    ps -p "$jamfHelperPID" > /dev/null && kill "$jamfHelperPID"; wait "$jamfHelperPID" 2>/dev/null
    writelog "Unable to detect a Thunderbolt volume in the amount of time specified; exiting."
    /bin/launchctl asuser "$loggedInUser" "$jamfHelper" -windowType utility -title "User Data Transfer" -icon "$icon" -description "We were unable to detect your old Mac. If you want to try again, please contact the Help Desk." -button1 "OK" -calcelButton "1" -defaultButton "1" &>/dev/null &
    exit 1
}

function getUserPassword () {

	userPassword="$(/bin/launchctl asuser "$loggedInUser" /usr/bin/osascript -e 'display dialog "Please enter the password for '"$loggedInUser"':" default answer "" with title "'"${PROMPT_TITLE//\"/\\\"}"'" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer' -e 'return text returned of result')"
	TRY=1
	until /usr/bin/dscl /Search -authonly "$loggedInUser" "$userPassword" &>/dev/null; do
	    (( TRY++ ))
	    writelog "Prompting $loggedInUser for their Mac password (attempt $TRY)..."
	    userPassword="$(/bin/launchctl asuser "$loggedInUser" /usr/bin/osascript -e 'display dialog "Sorry, that password was incorrect. Please try again:" default answer "" with title "'"${PROMPT_TITLE//\"/\\\"}"'" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer' -e 'return text returned of result')"
	    if (( TRY >= 5 )); then
	        writelog "[ERROR] Password prompt unsuccessful after 5 attempts. Displaying \"forgot password\" message..."
	        /bin/launchctl asuser "$loggedInUser" "$jamfHelper" \
	            -windowType "utility" \
	            -title "$PROMPT_TITLE" \
	            -description "$FORGOT_PW_MESSAGE" \
	            -button1 'OK' \
	            -defaultButton 1 \
	            -startlaunchd &>/dev/null &
	        return 1
	    fi
	done
	writelog "Successfully prompted for $loggedInUser password."
	return 0
}

function getOldUserPassword () {

	oldUserPassword="$(/bin/launchctl asuser "$loggedInUser" /usr/bin/osascript -e 'display dialog "Please enter the password for '"$oldUserName"' on your old Mac:" default answer "" with title "'"${PROMPT_TITLE//\"/\\\"}"'" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer' -e 'return text returned of result')"
	TRY=1
	until security unlock-keychain -p "$oldUserPassword" "$oldUserHome/Library/Keychains/login.keychain-db" 2>/dev/null; do
	    (( TRY++ ))
	    writelog "Prompting $loggedInUser for their old Mac password (account $oldUserName) (attempt $TRY)..."
	    oldUserPassword="$(/bin/launchctl asuser "$loggedInUser" /usr/bin/osascript -e 'display dialog "Sorry, that password was incorrect. Please try again:" default answer "" with title "'"${PROMPT_TITLE//\"/\\\"}"'" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer' -e 'return text returned of result')"
	    if (( TRY >= 5 )); then
	        writelog "[ERROR] Password prompt unsuccessful after 5 attempts. Displaying \"forgot password\" message..."
	        /bin/launchctl asuser "$loggedInUser" "$jamfHelper" \
	            -windowType "utility" \
	            -title "$PROMPT_TITLE" \
	            -description "$FORGOT_PW_MESSAGE" \
	            -button1 'OK' \
	            -defaultButton 1 \
	            -startlaunchd &>/dev/null &
	        return 1
	    fi
	done
	security lock-keychain "$oldUserHome/Library/Keychains/login.keychain-db"
	writelog "Successfully prompted for $oldUserName password."
	return 0
}

function checkUserPasswordAgainstOldKeychain () {
	local keychain="$oldUserHome/Library/Keychains/login.keychain-db"
	writelog "Checking password against old keychain ("$keychain")"
	security unlock-keychain -p "$userPassword" "$keychain" 2>&1 > $log
	local returnCode=$?
	[[ $returnCode == 0 ]] && security lock-keychain "$keychain"
	return $returnCode
}

function confirmConflictingUserDeletion () {
	dscl . list "/Users/$oldUserName"
	local userCode=$?
	if [[ "$userCode" == "0" ]]; then
		/bin/launchctl asuser "$loggedInUser" "$jamfHelper" \
						-windowType utility -title "User Data Transfer" \
						-icon "$icon" -description "Warning: A user account ($oldUserName) has been found on the new computer that will be overwritten.  Please click Okay to confirm this is okay." \
						-button1 "Okay" -button2 "Cancel" \
						-cancelButton "2" -defaultButton "1" > /tmp/output.txt
		return $?
	fi
	return 0
}

function isUserReadyForThis () {
	/bin/launchctl asuser "$loggedInUser" "$jamfHelper" \
					-windowType utility -title "User Data Transfer" \
					-icon "$icon" -description "$finalInstructions" \
					-button1 "Finish" -button2 "Cancel" \
					-cancelButton "2" -defaultButton "1" > /tmp/output.txt
	return $?
}

function makeMigratorUser () {
	sysadminctl -addUser migrator -fullName "Please Wait..." -password "$migratorUserPassword" -admin -adminUser "$loggedInUser" -adminPassword "$userPassword"  > $log 2>&1
}

function writeMigrationSettings () {
	writelog "Creating preferences file for LaunchDaemon."

	defaults write $preferences username "$oldUserName" && \
		defaults write $preferences userhome "$oldUserHome" && \
		defaults write $preferences password "$oldUserPassword" && \
		defaults write $preferences loggedInUser "$loggedInUser" && \
		return 0

	return 1
}

function writeLaunchDaemon () {
	writelog "Creating LaunchDaemon."
	cat << EOLAUNCHDAEMON > /Library/LaunchDaemons/com.alectrona.scripts.migratorTool.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.alectrona.scripts.migratorTool</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/jamf/bin/jamf</string>
		<string>policy</string>
		<string>-event</string>
		<string>thunderboltDataMigrationFinalize</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOLAUNCHDAEMON
}

function startLaunchDaemon () {
	writelog "Starting LaunchDaemon."
	launchctl load -w /Library/LaunchDaemons/com.alectrona.scripts.migratorTool.plist
}

writelog " "
writelog "======== Starting $scriptName ========"

#alectrona scriptSetup
caffeinate -d -i -m -u &
caffeinatepid=$!

# suppress TimeMachine offer to use thunderbolt drive as a backup drive
defaults write /Library/Preferences/com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool YES

# make admin
dseditgroup -o edit -n /Local/Default -a "$userFullname" -t user admin

# Wait for a GUI
wait_for_gui

# Exit if jamfHelper is not installed
if [[ ! -f "$jamfHelper" ]]; then
		writelog "Jamf Helper is not installed."
		exit 1
fi

checkSecureTokenStatus || exit 1

# TODO: CHECK VERSION

# Display a jamfHelper dialog with instructions as a background task
/bin/launchctl asuser "$loggedInUser" "$jamfHelper" -windowType utility \
		-windowPosition ul -title "User Data Transfer" -icon "$icon" \
		-description "$instructions" -button1 "Cancel" -button2 "Choose..." \
		-cancelButton "2" -defaultButton "1" > /tmp/output.txt &
jamfHelperPID=$(/bin/echo $!)

# Attempt to detect a new thunderbolt volume or let the user choose
detect_new_tbolt_volumes || choose_tbolt_volume || exit 2
writelog "Using Thunderbolt Volume: $tBoltVolume"

# Attempt to locate the user on the previous machine or prompt the user
auto_find_old_user || manually_find_old_user || exit 3
writelog "Using previous user: $oldUserName ($oldUserHome)"

# Calculate space requirements and alert the user if insufficient
calculate_space_requirements ||	exit 4

# Get User Password
getUserPassword || exit 5
# userPassword now contains the user's password, do not log it.

# Check to see that the password matches the old machine's keychain password.  If not, get the old password.
checkUserPasswordAgainstOldKeychain && { declare oldUserPassword=$userPassword } || getOldUserPassword || exit 6
# oldUserPassword now contains the user's old password, do not log it.

# Confirm deletion of conflicting user is okay
confirmConflictingUserDeletion || exit 7

# Perform rsync
perform_rsync || exit 8

# Make sure user is ready for this
isUserReadyForThis || exit 9

# if testing, exit
[[ $testing == true ]] && exit 0

# Make a migrator user
makeMigratorUser || exit 10

# set up the launchdaemon and trigger the final process
writeMigrationSettings && writeLaunchDaemon || exit 11

# do it!!!
startLaunchDaemon


#############
# Pseudocode Outline
#
## Check For Thunderbolt Volumes (detect_new_tbolt_volumes && choose_tbolt_volume) || exit no volumes found.
##		Assign Volume to variable
## Check for User (manually_find_old_user)
##		Assign User to a variable
## Calculate space requirements
## Collect User's New Password
##		Store in a variable
##		Check new password against old device login keychain
##		If different, ask for new device password
##			Store in a variable
## Copy files to a staging location (/Users/$username-migratorTool)
##		Verify?
## Inform user about what's about to happen - you'll be logged out, your user will be deleted, and a new one created
# Write the necessary information to a PLIST
# Start a launchdaemon to execute the final steps
#		Log out user
#		Delete existing account
#		Create new account (use old password for login password)
#		Move files into place

exit 0
