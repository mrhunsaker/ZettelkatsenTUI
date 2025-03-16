#!/usr/bin/env bash
######################################################################
#
# Copyright 2025 Michael Ryan Hunsaker, M.Ed., Ph.D.
#                <hunsakerconsulting@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
######################################################################
# Zettelkasten TUI - A simple TUI for managing a markdown-based 
#    Zettelkasten 
# Author: Michael Ryan Hunsaker, M.Ed., Ph.D. 
#    <hunsakerconsulting@gmail.com>
# Date: 2025-03-14
######################################################################

# Set variable defaults
ORIGINALS_DIR="originals"
RULES_FILE="rules.yml"
DICTIONARY_FILE="dictionary.yml"
LOG_FILE="zettelkasten.log"
DEFAULT_EDITOR="${EDITOR:-vim}" # Use $EDITOR environment variable or default to vim
DEBUG=false # Set to true for verbose logging

# Then load any custom values from variables.yml (if it exists)
load_variables

# Toggle debug mode
toggle_debug() {
  if [[ "$DEBUG" == "true" ]]; then
    DEBUG=false
    log "INFO" "Debug mode turned off"
  else
    DEBUG=true
    log "INFO" "Debug mode turned on"
  fi
}

# View log file
view_log() {
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "Log file doesn't exist yet."
    echo "Press any key to continue..."
    read -n 1
    return
  fi
  
  clear
  echo "=== LOG FILE CONTENTS ==="
  echo "File: $LOG_FILE"
  echo "=========================="
  
  # If less is available, use it for scrolling through the log
  if command -v less &> /dev/null; then
    less "$LOG_FILE"
  else
    cat "$LOG_FILE"
    echo
    echo "Press any key to continue..."
    read -n 1
  fi
}

# Create all folders from rules.yml
create_keyword_folders() {
  log "INFO" "Creating folders for all keywords in rules.yml..."
  
  # Check if rules file exists
  if [ ! -f "$RULES_FILE" ]; then
    log "ERROR" "Rules file does not exist: $RULES_FILE"
    echo "Error: Rules file does not exist."
    echo "Press any key to continue..."
    read -n 1
    return 1
  fi

  local rules_output=$(awk '!/^#/ && NF > 0 {gsub(/:/,"",$1); print $1, $2}' "$RULES_FILE")
  
  echo "$rules_output" | while read -r keyword folder; do
    if [[ -n "$folder" ]]; then
      if [ ! -d "$folder" ]; then
        mkdir -p "$folder"
        log "INFO" "Created folder: $folder for keyword: $keyword"
      else
        log "DEBUG" "Folder already exists: $folder for keyword: $keyword"
      fi
    fi
  done
  
  echo "All keyword folders created."
  echo "Press any key to continue..."
  read -n 1
}

process_files() {
  log "INFO" "Processing markdown files in $ORIGINALS_DIR..."
  create_keyword_folders

  # Check if originals directory exists
  if [ ! -d "$ORIGINALS_DIR" ]; then
    log "ERROR" "Originals directory does not exist: $ORIGINALS_DIR"
    echo "Error: Originals directory does not exist."
    echo "Press any key to continue..."
    read -n 1
    return 1
  fi
  
  # Check if rules file exists
  if [ ! -f "$RULES_FILE" ]; then
    log "ERROR" "Rules file does not exist: $RULES_FILE"
    echo "Error: Rules file does not exist."
    echo "Press any key to continue..."
    read -n 1
    return 1
  fi

  # Check if any markdown or org files exist
  markdown_count=$(find "$ORIGINALS_DIR" -type f \( -name "*.md" -o -name "*.org" \) 2>/dev/null | wc -l)
  if [ "$markdown_count" -eq 0 ]; then
    log "WARN" "No markdown or org files found in $ORIGINALS_DIR"
    echo "Warning: No markdown or org files found in $ORIGINALS_DIR."
    echo "Press any key to continue..."
    read -n 1
    return 0
  fi
  
  # Get all rules as associative array
  declare -A rules
  while read -r keyword folder; do
    rules["$keyword"]="$folder"
  done < <(parse_rules)
  
  # Count files for reporting
  total_files=$(find "$ORIGINALS_DIR" -type f -name "*.md" | wc -l)
  processed=0

  # Process each markdown or org file
  find "$ORIGINALS_DIR" -type f \( -name "*.md" -o -name "*.org" \) | while read -r file; do
    filename=$(basename "$file")
    realpath_file=$(realpath "$file")
    processed=$((processed + 1))
    log "INFO" "Processing file $processed/$total_files: $filename"
    
    # Apply sed command to replace [[keyword]] with {{keyword}} 
    # This is to avoid accidental replacement of wiki-styled links
    log "INFO" "Applying sed command to replace [[keyword]] with {{keyword}} in file: $filename"
    echo "Applying sed command to replace [[keyword]] with {{keyword}} in file: $filename"
    sed -E -i 's/\[\[([^]]*)\]\]/\{\{\1\}\}/g; s/\{\{(https?:\/\/[^}]*)\}\}/[[\1]]/g' "$file"

    # Dictionary entry for this file
    dict_entry="$filename:\n  - keyword: $filename\n  - uri: file://$realpath_file"

    # Extract keywords from file
    keywords=$(extract_keywords "$file")
    
    # Process each keyword found in the file
    echo "$keywords" | while read -r keyword; do
      if [[ -n "$keyword" && -n "${rules[$keyword]}" ]]; then
        folder="${rules[$keyword]}"
        
        # Create folder if it doesn't exist
        if [ ! -d "$folder" ]; then
          mkdir -p "$folder"
          log "INFO" "Created folder: $folder"
        fi
        
        # Create symlink if it doesn't exist
        symlink_path="$folder/$filename"
        if [ ! -L "$symlink_path" ]; then
          ln -s "$realpath_file" "$symlink_path"
          log "INFO" "Created symlink: $symlink_path"
          
          # Add to YAML dictionary entry
          dict_entry="$dict_entry\n  - symlink: file://$symlink_path"
        fi
      else
        if [[ -n "$keyword" ]]; then
          log "WARN" "Keyword '$keyword' not found in rules for file $filename"
        fi
      fi
    done

    # Update dictionary file - replace existing entry or add new one
    if grep -q "^$filename:" "$DICTIONARY_FILE"; then
      sed -i "/^$filename:/,/^$/c\\$dict_entry" "$DICTIONARY_FILE"
    else
      echo -e "$dict_entry" >> "$DICTIONARY_FILE"
    fi
  done

  # Log completion
  log "INFO" "Processing complete. Processed $total_files files."
}


# Initialize logging
log() {
  local level="$1"
  shift
  local message="$@"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
  
  # Print to stdout if debug is enabled or level is ERROR
  if [[ "$DEBUG" == "true" || "$level" == "ERROR" ]]; then
    echo "[$level] $message"
  fi
}

# Check if required tools are installed
for cmd in gawk grep sed find realpath readlink curl jq; do
  if ! command -v $cmd &> /dev/null; then
    log "ERROR" "$cmd is required but not installed."
    exit 1
  fi
done


# Initialize or create directories if they don't exist
initialize() {
  log "INFO" "Initializing Zettelkasten directories and files..."

  # Create originals directory if it doesn't exist
  if [ ! -d "$ORIGINALS_DIR" ]; then
    mkdir -p "$ORIGINALS_DIR"
    log "INFO" "Created originals directory"
  fi

  # Create rules.yml file with example if it doesn't exist
  if [ ! -f "$RULES_FILE" ]; then
    cat > "$RULES_FILE" << EOL
# Zettelkasten keyword mapping rules
# Format: keyword: folder
keyword1: folder1
EOL
    log "INFO" "Created example $RULES_FILE"
  fi

  # Create or reset dictionary.yml if using YAML
  if [ ! -f "$DICTIONARY_FILE" ]; then
    cat > "$DICTIONARY_FILE" << EOL
# Zettelkasten dictionary file
# Format: filename: [original_path, symlink1, symlink2, ...]
EOL
    log "INFO" "Created $DICTIONARY_FILE"
  fi
}

# Parse YAML rules file and extract keyword-folder mappings
parse_rules() {
  log "DEBUG" "Parsing rules from $RULES_FILE"
  
  # Use awk to extract keyword-folder mappings from rules.yml
  # Skip comments and empty lines
  awk '!/^#/ && NF > 0 {gsub(/:/,"",$1); print $1, $2}' "$RULES_FILE"
  
  # If using SQLite, sync rules to the database
  if [[ "$USE_SQLITE" == "true" ]]; then
    sync_rules_to_db
  fi
}

# Find all keywords within {{}} in a file
extract_keywords() {
  local file="$1"
  log "DEBUG" "Extracting keywords from $file"
  
  # Extract keywords within {{ }}
  keywords=$(grep -o '{{[^}]*}}' "$file" | sed 's/{{//g; s/}}//g')
  
  if [[ -z "$keywords" ]]; then
    log "DEBUG" "No keywords found in $file"
  else
    log "DEBUG" "Found keywords in $file: $keywords"
  fi
  
  echo "$keywords"
}

create_new_markdown() {

  # Prompt for title
  echo -n "Enter document title: "
  read TITLE
  
  # Use a default title if none provided
  if [[ -z "$TITLE" ]]; then
    TITLE="Untitled_Note"
  fi
  
  # Create timestamp
  TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
  TODAY=$(date +"%Y-%m-%d")
  
  # Create temp file directly with the provided title
  TEMP_FILE="$(mktemp /tmp/md_edit.XXXXXX.md)"
  
  # Create the markdown file with the title already inserted
  cat > "$TEMP_FILE" << EOF
---
title: $TITLE
date: $TODAY
open_timestamp: $(date +"%Y-%m-%d %H:%M:%S")
save_timestamp: 
tags: []
---
# $TITLE

## Keywords
(enclose keywords in double curly braces)

EOF
  
  # Create safe filename (remove special chars, replace spaces with underscores)
  SAFE_TITLE=$(echo "$TITLE" | tr ' ' '_' | tr -cd '[:alnum:]_-')
  
  # Generate the final filename
  FINAL_FILE="${ORIGINALS_DIR}/${SAFE_TITLE}_${TIMESTAMP}.md"
  
  # Open the file in vim
  vim "$TEMP_FILE"
  
  # Move the edited file to the originals directory after vim exits
  mv "$TEMP_FILE" "$FINAL_FILE"
  
  echo "File saved as: $FINAL_FILE"
  echo "Press any key to continue..."
  read -n 1
}


# TUI menu using dialog or a simple select loop
show_tui() {
  while true; do
    clear
    echo "=========================================="
    echo "           ZETTELKASTEN MANAGER          "
    echo "=========================================="
    echo "1. Create new Markdown file"
    echo "2. Process all files"
    echo "3. Select originals directory"
    echo "4. Browse by keyword"
    echo "5. Edit rules file"
    echo "8. View dictionary"
    echo "11. Toggle debug mode (current: $(if [[ "$DEBUG" == "true" ]]; then echo "ON"; else echo "OFF"; fi))"
    echo "12. View log file"
    echo "15. Schedule daily processing"
    echo "q. Quit"
    echo "=========================================="
    echo -n "Select an option: "
    read -r choice
    
    case "$choice" in
      1|n) create_new_markdown ;;
      2|p) process_files ;;
      3) select_originals_dir ;;
      4) browse_by_keyword ;;
      5) $DEFAULT_EDITOR "$RULES_FILE" ;;
      8) view_dictionary ;;
      11) toggle_debug ;;
      12) view_log ;;
      15) schedule_daily_processing ;;
      q|Q) echo "Goodbye!"; exit 0 ;;
      *) echo "Invalid option. Press any key to continue..."; read -n 1 ;;
    esac
  done
}

# Function to open a file in the system's default markdown editor
open_in_default_editor() {
  local file="$1"
  if command -v xdg-open &> /dev/null; then
    xdg-open "$file"
  else
    echo "xdg-open is not installed. Please install it to use this feature."
    echo "Press any key to continue..."
    read -n 1
  fi
}

# Browse files by keyword
browse_by_keyword() {
  log "INFO" "Browsing files by keyword..."
  
  # Check if rules file exists
  if [ ! -f "$RULES_FILE" ]; then
    log "ERROR" "Rules file does not exist: $RULES_FILE"
    echo "Error: Rules file does not exist."
    echo "Press any key to continue..."
    read -n 1
    return 1
  fi
  
  # Extract all keywords and their folders
  keyword_list=$(awk '!/^#/ && NF > 0 {gsub(/:/,"",$1); print $1}' "$RULES_FILE" | sort)
  
  if [[ -z "$keyword_list" ]]; then
    log "ERROR" "No keywords found in rules file"
    echo "No keywords found in rules file. Please add some rules first."
    echo "Press any key to continue..."
    read -n 1
    return 1
  fi
  
  # Create an array of keywords for select command
  readarray -t keywords <<< "$keyword_list"
  
  # Add a Return option
  keywords+=("Return to main menu")
  
  # Display keyword selection menu
  clear
  echo "=== BROWSE BY KEYWORD ==="
  echo "Select a keyword to see associated files:"
  echo
  
  select keyword in "${keywords[@]}"; do
    if [[ "$keyword" == "Return to main menu" ]]; then
      return 0
    elif [[ -n "$keyword" ]]; then
      # Find the folder for this keyword
      folder=$(awk -v kw="$keyword" '$1 == kw {print $2}' "$RULES_FILE")
      
      # If folder is empty, use keyword as folder name (common convention)
      if [[ -z "$folder" ]]; then
        folder="$keyword"
      fi
      
      # Prepend katsen/ to the folder path
      folder="katsen/$folder"
      
      if [[ -d "$folder" ]]; then
        # List all files in the selected folder - both symlinks and regular files
        file_list=$(find "$folder" -maxdepth 1 -type f -o -type l -name "*.md" -o -name "*.org" | sort)
        
        if [[ -z "$file_list" ]]; then
          echo "No files found with keyword '$keyword' in folder '$folder'."
          echo "Press any key to continue..."
          read -n 1
          break
        fi
        
        # Create an array of files for select command
        readarray -t files <<< "$file_list"
        
        # Add a Return option
        files+=("Return to keywords")
        
        # Display file selection menu
        clear
        echo "=== FILES WITH KEYWORD '$keyword' (in folder '$folder') ==="
        echo
        
        select file in "${files[@]}"; do
          if [[ "$file" == "Return to keywords" ]]; then
            break
          elif [[ -n "$file" ]]; then
            # Ask the user how they want to open the file
            echo "How would you like to open the file?"
            echo "1. Open in default markdown editor"
            echo "2. Open in terminal editor ($DEFAULT_EDITOR)"
            echo "3. Cancel"
            read -p "Select an option: " open_choice
            
            case "$open_choice" in
              1)
                open_in_default_editor "$file"
                ;;
              2)
                if [[ -L "$file" ]]; then
                  # If it's a symlink, get the target
                  target=$(readlink -f "$file")
                  $DEFAULT_EDITOR "$target"
                else
                  $DEFAULT_EDITOR "$file"
                fi
                ;;
              3)
                break
                ;;
              *)
                echo "Invalid option. Please try again."
                ;;
            esac
            break
          else
            echo "Invalid file selection. Please try again."
          fi
        done
      else
        echo "Folder '$folder' for keyword '$keyword' does not exist yet."
        echo "Press any key to continue..."
        read -n 1
      fi
      break
    else
      echo "Invalid keyword selection. Please try again."
    fi
  done
}

# Select location for originals directory
select_originals_dir() {
    clear
    echo "=== SELECT ORIGINALS DIRECTORY ==="
    echo "Current location: $ORIGINALS_DIR"
    echo "Enter new location (or press Enter to use default: ./originals/):"
    read -r new_dir
    if [[ -z "$new_dir" ]]; then
        new_dir="$HOME/Documents/Zettelkatsen/originals"
    fi
    ORIGINALS_DIR="$new_dir"
    
    # Create the directory if it doesn't exist
    if [ ! -d "$ORIGINALS_DIR" ]; then
        mkdir -p "$ORIGINALS_DIR"
        log "INFO" "Created originals directory at $ORIGINALS_DIR"
    fi
    
    # Update the variables.yml file with the new ORIGINALS_DIR
    update_variables_file
    
    echo "Originals directory set to: $ORIGINALS_DIR"
    echo "Press any key to continue..."
    read -n 1
}

# Function to create or update the variables.yml file
update_variables_file() {
    local variables_file="variables.yml"
    
    # Create the variables.yml content
    cat > "$variables_file" << EOF
# Zettelkasten Configuration Variables
# Last updated: $(date)

# Directories and Files
ORIGINALS_DIR: "$ORIGINALS_DIR"
RULES_FILE: "$RULES_FILE"
DICTIONARY_FILE: "$DICTIONARY_FILE"
LOG_FILE: "$LOG_FILE"
DEFAULT_EDITOR: "${DEFAULT_EDITOR}"

# Settings
DEBUG: $DEBUG
EOF

    log "INFO" "Updated variables configuration in $variables_file"
}

# Function to schedule daily processing of files using cron
schedule_daily_processing() {
  clear
  echo "=== SCHEDULE DAILY PROCESSING ==="
  echo "Enter the time to run the process_files function every day (in 24-hour format, e.g., 14:00):"
  read -r time

  # Validate the time format
  if [[ ! "$time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "Invalid time format. Please enter the time in HH:MM format."
    echo "Press any key to continue..."
    read -n 1
    return 1
  fi

  # Extract hours and minutes
  hour=$(echo "$time" | cut -d: -f1)
  minute=$(echo "$time" | cut -d: -f2)

  # Get the full path to the script
  script_path=$(realpath "$0")

  # Add the cron job
  (crontab -l 2>/dev/null; echo "$minute $hour * * * $script_path --process-files") | crontab -

  echo "Scheduled daily processing at $time."
  echo "Press any key to continue..."
  read -n 1
}

# Function to load variables from variables.yml
load_variables() {
    local variables_file="variables.yml"
    
    # Check if variables file exists
    if [ -f "$variables_file" ]; then
        # Parse YAML and set variables
        # Using simple grep/sed approach for basic YAML parsing
        ORIGINALS_DIR=$(grep "^ORIGINALS_DIR:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        RULES_FILE=$(grep "^RULES_FILE:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        DICTIONARY_FILE=$(grep "^DICTIONARY_FILE:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        LOG_FILE=$(grep "^LOG_FILE:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        DEFAULT_EDITOR=$(grep "^DEFAULT_EDITOR:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        DEBUG=$(grep "^DEBUG:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        
        log "INFO" "Loaded variables from $variables_file"
    else
        log "WARNING" "Variables file $variables_file not found, using defaults"
    fi
}


# Main function
main() {
  initialize
  show_tui
}

# Execute the main function
main
