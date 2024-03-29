#!/bin/bash
# Copyright (C) 2014  Roman Zimbelmann <hut@lepus.uberspace.de>
# This software is distributed under the terms of the GNU GPL version 3.

players=()
copydir=""
movedir=""
LSCD_VERSION=0.1

f () {
    # This function gives quick access to the "$f" variable.
    # instead of 'mplayer "$f"' you can write 'f mplayer'.
    "$@" "$f"
}

lscd_base () {
    if [ "$1" == "--version" -o "$1" == "-v" ]; then
        echo "lscd $LSCD_VERSION"
        return
    elif [ "$1" == "--help" -o "$1" == "-h" ]; then
        echo "usage: lscd [-v | --version | -h | --help]"
        return
    fi

    # Initialize position variables
    local index=1   # the number of the topmost visible line
    local cursor=0  # the number of the selected file, relative to index
    local offset=3  # number of the lines on the GUI not used for files, plus 1
    local total=0   # total number of files in this directory
    local total_visible=0

    # Variables related to the GUI
    local redraw=1  # should the draw() function be entered?
    local reprint=1 # should the interface be redrawn?

    # Initialize settings
    local BOOL_show_hidden=
    local BOOL_clear=
    local BOOL_show_info=
    local STRING_file_opener=rifle
    local STRING_filter= #"(\.mp3$|\.wav$|\.aiff$|\.iff$|\.ogg$|\.flac$)"
    local INT_step=6

    # Alternative file opener (less) if rifle is not installed
    type -t "$STRING_file_opener" > /dev/null 2>&1
    [ "$?" -eq 1 ] && STRING_file_opener=less

    # Change the terminal environment
    local stty_orig=`stty -g`
    stty -echo
    local save_traps="$(trap)"

    # Set up signal handlers
    trap on_resize SIGWINCH
    #trap on_exit SIGINT

    # Signal handler for resizing, also executed when typing Ctrl+L
    on_resize () {
        redraw=1
        reprint=1
    }

    # This function cleans up the environment on exiting.
    on_exit () {
        # Restore the terminal
        stty $stty_orig

        # Restore signal handlers
        eval "$save_traps"

        # Place the cursor at a sane position
        [ -z "$total" ] && total="$(listfiles | wc -l)"
        printf "\033[$((total - index + offset));1H"
      
        kill_audio
    }

    # Determine the dimensions of the screen
    get_dimensions () {
        cols="$(tput cols)"
        lines="$(tput lines)"
    }

    # Get a single character that's typed in by the user
    getc () {
        stty raw
        dd bs=1 count=1 2>/dev/null
        stty cooked
    }

    # A function used for moving the cursor around
    move () {
        local arg="$1"
        local new_cursor

        redraw=1
        max_index="$((total - total_visible + 1))"
        max_cursor="$((total_visible - 1))"

        # Save the previous index value to determine if ui should be redrawn
        old_index="$index"

        # Add the argument to the current cursor
        cursor="$((cursor + arg))"

        if [ "$cursor" -ge "$total_visible" ]; then
            # Cursor moved past the bottom of the list

            if [ "$total_visible" -ge "$total" ]; then
                # The list fits entirely on the screen.
                index=1
            else
                # The list doesn't fit on the screen.
                if [ "$((index + cursor))" -gt "$total" ]; then
                    # Cursor out of bounds. Put it at the very bottom.
                    index="$max_index"
                else
                    # Move the index down so the visible part of the list
                    # also shows the cursor
                    difference="$((total_visible - 1 - cursor))"
                    index="$((index - difference))"
                fi
            fi

            # In any case, place the cursor on the last file.
            cursor="$max_cursor"
        fi

        if [ "$cursor" -lt 0 ]; then
            # Cursor is above the list, so scroll up.
            index="$((index + cursor))"
            cursor=0
        fi

        # The index should always be >0 and <$max_index
        [ "$index" -gt "$max_index" ] && index="$max_index"
        [ "$index" -lt 1 ] && index=1

        if [ "$index" != "$old_index" ]; then
            # Redraw if the index (and thus the visible files) has changed
            reprint=1

            # Jump a step when scrolling
            if [ "$index" -gt "$old_index" ]; then
                # Jump a step down
                step="$((max_index - index))"
                [ "$step" -gt "$INT_step" ] && step="$INT_step"
                index="$((index + step))"
                cursor="$((cursor - step))"
            else
                # Jump a step up
                step="$((index - 1))"
                [ "$step" -gt "$INT_step" ] && step="$INT_step"
                index="$((index - step))"
                cursor="$((cursor + step))"
            fi
        fi

        # The index should always be >0 and <$max_index
        [ "$index" -gt "$max_index" ] && index="$max_index"
        [ "$index" -lt 1 ] && index=1
    }

    # Erase the screen by filling each row with whitespaces
    erase () {
        local i="$lines"
        while [ "$i" -gt 0 ]; do
            printf "\033[$i;1H\033[K"
            i="$((i-1))"
        done
    }

    # Run the command that lists all the files for displaying
    _listfiles () {
        local args
        if [ "$1" == "-v" ]; then
            args="--color"
        else
            args=
        fi
        test -n "$BOOL_show_hidden" && args="$args -A"

        if [ -n "$BOOL_show_info" -a "$1" == "-v" ]; then
            # Strip off the summary line
            ls --group-directories-first -X $args -l | tail -n +2
        else
            ls --group-directories-first -X $args
        fi
    }

    # Filter the files from _listfiles by grepping for the $STRING_filter option
    listfiles () {
        if [ -n "$STRING_filter" ]; then
            _listfiles "$@" | grep -E "$STRING_filter"
        else
            _listfiles "$@"
        fi
    }

    # Change the directory
    movedir () {
        redraw=1
        reprint=1
        index=1
        cursor=0
        STRING_filter=
        cd "$1"
    }

    # The drawing function
    draw () {
        get_dimensions

        # Erase the screen if necessary
        if [ -n "$reprint" ]; then
            if [ -n "$BOOL_clear" ]; then
                clear
            else
                erase
            fi
        fi

        # Determine the number of total files in the directory
        total="$(listfiles | wc -l)"

        # Determine the number of visible files 
        if [ "$total" -gt "$((lines - offset + 1))" ]; then
            total_visible="$((lines - offset + 1))"
        else
            total_visible="$total"
        fi

        # Determine the current file
        f="$(listfiles | tail -n +"$((index + cursor))" | head -n 1)"

        # Print the header and the list of files
        if [ -n "$reprint" ]; then
            # Move to the first line and erase it
            printf "\033[1;1H\033[K"
            # Print the header
            printf "\033[1;32m$USER@$(hostname):\033[1;34m$(pwd)\033[00m\n"
            # List the files and cut out the currently visible part
            listfiles -v | tail -n +"$index" | head -n "$((lines - 2))" | sed 's/\(.\{'"$cols"'\}\).*/\1/;'
        fi

        # Clear the gui flags
        redraw=
        reprint=

        # Move the cursor to the requested position
        printf "\033[$((cursor + 2));1H"
    }

    # Handle the currently selected file/directory depending on file type
    openfile () {
        f="$1"
        [ -z "$f" ] && return
        filetype="$(stat -Lc %F "$f")"
        case "$filetype" in
            directory)
                movedir "$f";;
            *)
                play_audio "$f" || {
                  $STRING_file_opener "$f"
                  redraw=1;
                }
                ;;
        esac
    }

    # The program loop that handles the input and draws the interface
    echo -e "Audiobrowse v1.0 keys:\n"
    printf "  %-20s %s\n" "'.' + arrow keys" "directory navigation"
    printf "  %-20s %s\n" "<enter>" "preview audio"
    printf "  %-20s %s\n" "'f'" "filter results"
    printf "  %-20s %s\n" "'m'" "move file to <dir>"
    printf "  %-20s %s\n" "'c'" "copy file to <dir>"
    printf "  %-20s %s\n" "'q'" "quit"
    echo -e "\npress key to start.." 
    while read -sN1 input; do
        # Get the input
        #input="$(getc)"

        # catch special key sequences
        builtin read -sN1 -t 0.0001 k1
        builtin read -sN1 -t 0.0001 k2
        builtin read -sN1 -t 0.0001 k3
        #[ "$input" == $'\e' ] && input=ESC
        input+="${k1}${k2}${k3}"

        # Handle the input
        case "$input" in
            j|$'\e[A'|$'\e0A')
                move 1;;
            k|$'\e[B'|$'\e0B')
                move -1;;
            $'\e[6'|$'\e[C'|$'\eOC')
                move 10;;
            $'\e[5'|$'\e[D'|$'\eOD')
                move -10;;
            g)
                # Enter the key chain for quickly changing the directory
                input="$(getc)"
                case "$input" in
                    -) movedir -;;
                    /) movedir /;;
                    b) movedir /boot;;
                    d) movedir /dev;;
                    e) movedir /etc;;
                    f) movedir /var/ftp;;
                    g) move -9999999999;;
                    h) movedir ~;;
                    i) movedir /usr/include;;
                    l) movedir /usr/lib;;
                    L) movedir /var/log;;
                    m) movedir /media;;
                    M) movedir /mnt;;
                    o) movedir /opt;;
                    p) movedir /proc;;
                    r) movedir /;;
                    R) movedir /root;;
                    S) movedir /srv;;
                    s) movedir /sys;;
                    t) movedir /tmp;;
                    T) movedir /var/tmp;;
                    u) movedir /usr;;
                    v) movedir /var;;
                    w) movedir /var/www;;
                esac;;
            G)
                move 9999999999;;
            \.|h|'ESC[D')
                movedir ..;;
            l|'ESC[C'|$'\0d')
                openfile "$f"
                #reprint=1;;
                ;;
            f)
                # Open a prompt for entering the filter
                printf "\033[99999;1H"
                stty $stty_orig
                read -p "filter on: " STRING_filter
                stty -echo
                redraw=1
                reprint=1
                move -9999999999;;
            e)
                # Open the current file in an editor
                if [ -n "$EDITOR" ]; then
                    "$EDITOR" "$f"
                else
                    vim "$f"
                fi
                redraw=1;;
            z)
                # Toggle displaying hidden files
                if [ -z "$BOOL_show_hidden" ]; then BOOL_show_hidden=1; else BOOL_show_hidden=; fi
                reprint=1
                redraw=1;;
            x)
                # Toggle showing additional file information
                if [ -z "$BOOL_show_info" ]; then BOOL_show_info=1; else BOOL_show_info=; fi
                reprint=1
                redraw=1;;
            $'\x0c') # CTRL+L
                on_resize;;
            q)
                on_exit;
                exit 0;;
            m)
                reprint=1
                redraw=1
                [[ "${#movedir}" == 0 ]] && {
                  printf "\033[99999;1H"
                  stty $stty_orig
                  read -p "please specify dir to move files to: " movedir
                  stty -echo
                  [[ ! -d "$movedir" ]] && { mkdir "$movedir" || break; }
                }
                mv "$f" "$movedir"/.
                ;;
            c)
                reprint=1
                redraw=1
                [[ "${#copydir}" == 0 ]] && {
                  printf "\033[99999;1H"
                  stty $stty_orig
                  read -p "please specify dir to copy files to: " copydir
                  stty -echo
                  [[ ! -d "$copydir" ]] && { mkdir "$copydir" || break; }
                }
                cp "$f" "$copydir"/.
                ;;
            ?)
                info_audio "$f"
                echo ""; read -p "press a key.." p
                reprint=1
                redraw=1
                ;;
        esac
        # Redraw the interface if requested
        test -n "$redraw" && draw
    done

}

info_audio(){
  which sox &>/dev/null || return 0
  clear
  echo "$(pwd)/$1"
  file "$1"
  sox "$1" -n stat 
}

kill_audio(){  
  for p in ${players[@]}; do killall -s SIGINT $(basename $p) &>/dev/null; done 
}

play_audio(){
  file="$1"
  [[ ! "$file" =~ \.mp3$|\.wav$|\.aiff$|\.iff$|\.ogg$|\.flac$ ]] && return 1
  players=()
  [[ "$file" =~ \.ogg$ ]] && players+=("$(which ogg123)")
  [[ "$file" =~ \.mp3$ ]] && {
    which mplayer  &>/dev/null && players+=("$(which mplayer) -novideo")
    which mpg123 &>/dev/null && players+=("$(which mpg123)")
  }
  [[ "$file" =~ \.wav$|\.aiff$|\.iff$ ]] && {
    which play   &>/dev/null && players+=("$(which play)")
    which mplayer   &>/dev/null && players+=("$(which mplayer) -novideo")
    which paplay &>/dev/null && players+=("$(which paplay)")
    which aplay  &>/dev/null && players+=("$(which aplay)");
  }
  kill_audio
  player="${players[0]}"
  ${player} "$file" &>/dev/null &
  return 0
}

lscd_base "$@"
