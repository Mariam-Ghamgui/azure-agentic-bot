#!/bin/bash

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  local -n arg_defs=$1
  shift
  local args=("$@")
  for arg_name in "${!arg_defs[@]}"; do
    declare -g "$arg_name"="${arg_defs[$arg_name]}"
  done
  for ((i = 0; i < ${#args[@]}; i++)); do
    local arg=${args[i]}
    if [[ $arg == --* ]]; then
      local arg_name=${arg#--}
      local next_index=$((i + 1))
      local next_arg=${args[$next_index]}
      if [[ -z ${arg_defs[$arg_name]+_} ]]; then
        continue
      fi
      if [[ $next_arg == --* ]] || [[ -z $next_arg ]]; then
        declare -g "$arg_name"=1
      else
        declare -g "$arg_name"="$next_arg"
        ((i++))
      fi
    else
      break
    fi
  done
}

install_yq() {
  if ! command_exists yq; then
    echo "[yq] is not installed. Installing [yq]..."
    sudo apt-get update -y >/dev/null 2>&1
    sudo apt-get install -y jq wget >/dev/null 2>&1
    local latest_yq_version
    latest_yq_version=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d '"' -f 4)
    sudo wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${latest_yq_version}/yq_linux_amd64"
    sudo chmod +x /usr/local/bin/yq
    command_exists yq || { echo "Failed to install [yq]."; exit 1; }
  fi
}

activate_venv() {
  if [ -d "pf" ]; then
    echo "Activating virtual environment [pf]..."
    source pf/bin/activate
  else
    echo "Virtual environment [pf] not found. Please create it in the workflow."
    exit 1
  fi
}

install_promptflow() {
  activate_venv
  export AZURE_EXTENSION_USE_PYTHON=$(which python3.11)
  pip install --upgrade pip >/dev/null 2>&1
  pip install "promptflow[azure]" --upgrade >/dev/null 2>&1
  pip show promptflow >/dev/null 2>&1 || { echo "Failed to install promptflow."; exit 1; }
}

install_ml_extension() {
  export AZURE_EXTENSION_USE_PYTHON=$(which python)
  az extension show --name ml &>/dev/null || az extension add --name ml --upgrade --only-show-errors
}

replace_yaml_field() {
  local yaml_file="$1"
  local field_path="$2"
  local search_value="$3"
  local replace_value="$4"
  yq eval ".${field_path} |= sub(\"${search_value}\", \"${replace_value}\")" "$yaml_file" -i
}

set_yaml_field() {
  local yaml_file="$1"
  local field_path="$2"
  local new_value="$3"
  yq eval ".${field_path} = \"${new_value}\"" "$yaml_file" -i
}

generate_new_filename() {
  local file="$1"
  local filename=$(basename "$file")
  local name="${filename%.*}"
  local extension="${filename##*.}"
  local current_datetime=$(date +"%Y-%m-%d-%H-%M-%S")
  echo "${name}-${current_datetime}.${extension}"
}

create_new_directory() {
  local directory="$1"
  rm -rf "$directory" && mkdir -p "$directory" || {
    echo "Error managing directory [$directory]."
    exit 1
  }
}

remove_directory() {
  local directory="$1"
  [ -d "$directory" ] && rm -rf "$directory"
}