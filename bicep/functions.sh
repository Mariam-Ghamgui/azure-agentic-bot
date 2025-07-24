#!/bin/bash

# Helper function to parse named command-line arguments into variables
parse_args() {
    # $1 - The associative array name containing the argument definitions and default values
    # $2 - The arguments passed to the script
    local -n arg_defs=$1 # -n creates a reference to the associative array
    shift # Remove the first argument (the array reference)
    local args=("$@") # Store remaining arguments in an array

    # Assign default values first for defined arguments
    for arg_name in "${!arg_defs[@]}"; do
        declare -g "$arg_name"="${arg_defs[$arg_name]}" # -g makes variables global
    done

    # Process command-line arguments
    for ((i = 0; i < ${#args[@]}; i++)); do
        arg=${args[i]}

        # Only process arguments starting with --
        if [[ $arg == --* ]]; then
            arg_name=${arg#--} # Remove -- prefix
            next_index=$((i + 1))
            next_arg=${args[$next_index]}

            # Check if the argument is defined in arg_defs
            if [[ -z ${arg_defs[$arg_name]+_} ]]; then
                # Argument not defined, skip setting
                continue
            fi

            if [[ $next_arg == --* ]] || [[ -z $next_arg ]]; then
                # Treat as a flag (no value follows)
                declare -g "$arg_name"=1
            else
                # Treat as a value argument
                declare -g "$arg_name"="$next_arg"
                ((i++)) # Skip the next argument since we consumed it as a value
            fi
        else
            # Stop processing if we encounter a non --argument
            break 
        fi
    done
}