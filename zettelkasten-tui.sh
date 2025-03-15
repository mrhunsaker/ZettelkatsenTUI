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
DB_FILE="zettelkasten.db"
LOG_FILE="zettelkasten.log"
DEFAULT_EDITOR="${EDITOR:-vim}" # Use $EDITOR environment variable or default to vim
USE_SQLITE=false # Set to false to use YAML instead of SQLite for dictionary
DEBUG=false # Set to true for verbose logging
# Gemini API settings
GEMINI_API_KEY="" # Your Gemini API key here
GEMINI_API_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent"

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

# Toggle between SQLite and YAML storage
toggle_storage() {
  if [[ "$USE_SQLITE" == "true" ]]; then
    USE_SQLITE=false
    log "INFO" "Switched to YAML storage"
  else
    # Check if sqlite3 is installed before switching
    if command -v sqlite3 &> /dev/null; then
      USE_SQLITE=true
      
      # Initialize database if it doesn't exist
      if [ ! -f "$DB_FILE" ]; then
        init_sqlite_db
      fi
      
      log "INFO" "Switched to SQLite storage"
    else
      echo "SQLite3 is not installed. Cannot switch to SQLite storage."
      echo "Please install sqlite3 first."
      echo "Press any key to continue..."
      read -n 1
    fi
  fi
}

# Configure Gemini API
configure_gemini() {
  clear
  echo "=== GEMINI API CONFIGURATION ==="
  
  # Load current configuration
  if [ -f "gemini_config.json" ]; then
    current_key=$(jq -r '.api_key' gemini_config.json)
    current_enabled=$(jq -r '.enabled' gemini_config.json)
    current_temp=$(jq -r '.temperature' gemini_config.json)
    current_tokens=$(jq -r '.max_output_tokens' gemini_config.json)
  else
    # Default values
    current_key=""
    current_enabled="false"
    current_temp="0.2"
    current_tokens="1024"
  fi
  
  # Show current configuration
  echo "Current settings:"
  echo "API Key: ${current_key:0:4}$(if [[ -n "$current_key" ]]; then echo "****"; fi)"
  echo "Enabled: $current_enabled"
  echo "Temperature: $current_temp"
  echo "Max Tokens: $current_tokens"
  echo
  
  # Get new API key
  echo -n "Enter new API key (or press Enter to keep current): "
  read -r new_key
  
  if [[ -z "$new_key" ]]; then
    new_key="$current_key"
  fi
  
  # Toggle enabled status
  echo -n "Enable Gemini API? (y/n): "
  read -r enable_resp
  
  if [[ "$enable_resp" =~ ^[Yy] ]]; then
    new_enabled="true"
  else
    new_enabled="false"
  fi
  
  # Get temperature
  echo -n "Enter temperature (0.0-1.0, default 0.2): "
  read -r new_temp
  
  if [[ -z "$new_temp" ]]; then
    new_temp="$current_temp"
  elif ! [[ "$new_temp" =~ ^0*(\.[0-9]+)?$ || "$new_temp" =~ ^[01](\.[0-9]+)?$ ]]; then
    echo "Invalid temperature. Using default 0.2."
    new_temp="0.2"
  fi
  
  # Get max tokens
  echo -n "Enter max output tokens (default 1024): "
  read -r new_tokens
  
  if [[ -z "$new_tokens" ]]; then
    new_tokens="$current_tokens"
  elif ! [[ "$new_tokens" =~ ^[0-9]+$ ]]; then
    echo "Invalid token count. Using default 1024."
    new_tokens="1024"
  fi
  
  # Save configuration
  cat > "gemini_config.json" << EOL
{
  "api_key": "$new_key",
  "enabled": $new_enabled,
  "temperature": $new_temp,
  "max_output_tokens": $new_tokens
}
EOL
  
  # Update global variables
  GEMINI_API_KEY="$new_key"
  GEMINI_ENABLED="$new_enabled"
  
  log "INFO" "Updated Gemini API configuration"
  
  echo "Configuration saved."
  echo "Press any key to continue..."
  read -n 1
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
  
  # If using SQLite, make sure we're not causing conflicts
  if [[ "$USE_SQLITE" == "true" ]]; then
    # Try to end any existing transactions and make sure DB isn't locked
    for i in {1..5}; do  # Try a few times with delays
      sqlite3 "$DB_FILE" "PRAGMA busy_timeout=2000;" 2>/dev/null
      sqlite3 "$DB_FILE" "COMMIT;" 2>/dev/null || true
      sqlite3 "$DB_FILE" "ROLLBACK;" 2>/dev/null || true
      
      # Check if database is locked
      if ! sqlite3 "$DB_FILE" "PRAGMA quick_check;" &>/dev/null; then
        log "WARN" "Database appears to be locked, waiting..."
        sleep 2  # Wait a bit longer between attempts
      else
        break  # Database is accessible, proceed
      fi
    done
  fi
  
  # Just create folders directly from the rules file without syncing to DB here
  # This avoids potential DB locking issues
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

  if [[ "$USE_SQLITE" == "true" ]]; then
    sync_rules_to_db
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

  # Start a transaction for batch processing
  sqlite3 "$DB_FILE" "BEGIN TRANSACTION;"

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
    dict_entry="$filename: [$(realpath "$file")"

    if [[ "$USE_SQLITE" == "true" ]]; then
      # Add or update file in SQLite
      add_file_to_db "$filename" "$realpath_file"
      file_id=$(sqlite3 "$DB_FILE" "SELECT id FROM files WHERE original_path='$realpath_file';")
    fi
    
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
          dict_entry="$dict_entry, $(realpath "$symlink_path")"

          if [[ "$USE_SQLITE" == "true" ]]; then
            # Get keyword_id with proper error handling
            safe_keyword=$(echo "$keyword" | sed "s/'/''/g")
            keyword_id=$(sqlite3 "$DB_FILE" "SELECT id FROM keywords WHERE keyword='$safe_keyword';")
            
            if [[ -n "$keyword_id" ]]; then
              # Add file-keyword relationship and symlink with proper escaping
              realpath_symlink=$(realpath "$symlink_path")
              safe_symlink=$(echo "$realpath_symlink" | sed "s/'/''/g")
              
              sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO file_keywords (file_id, keyword_id, symlink_path) VALUES ($file_id, $keyword_id, '$safe_symlink');"
              
              # Log success or failure
              if [ $? -eq 0 ]; then
                log "INFO" "Added relationship to database: file_id=$file_id, keyword_id=$keyword_id, symlink=$symlink_path"
              else
                log "ERROR" "Failed to add relationship to database: file_id=$file_id, keyword_id=$keyword_id"
              fi
            else
              log "ERROR" "Keyword ID not found for '$keyword'"
            fi
          fi
        fi
      else
        if [[ -n "$keyword" ]]; then
          log "WARN" "Keyword '$keyword' not found in rules for file $filename"
        fi
      fi
    done

    # Finalize YAML dictionary entry
    dict_entry="$dict_entry]"
    
    # Update dictionary file - replace existing entry or add new one
    if grep -q "^$filename:" "$DICTIONARY_FILE"; then
      sed -i "s|^$filename:.*|$dict_entry|" "$DICTIONARY_FILE"
    else
      echo "$dict_entry" >> "$DICTIONARY_FILE"
    fi
  done

  # Commit the transaction
  if ! sqlite3 "$DB_FILE" "COMMIT;"; then
    log "ERROR" "Failed to commit transaction"
    sqlite3 "$DB_FILE" "ROLLBACK;"
    return 1
  fi
  
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

# Check for SQLite if enabled
if [[ "$USE_SQLITE" == "true" ]]; then
  if ! command -v sqlite3 &> /dev/null; then
    log "ERROR" "SQLite3 is required but not installed. Install it or set USE_SQLITE=false"
    exit 1
  fi
fi

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
philosophy: philosophy
programming: code
ideas: concepts
project: projects
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
  
  # Initialize SQLite database if enabled
  if [[ "$USE_SQLITE" == "true" ]]; then
    init_sqlite_db
  fi
  
  # Create Gemini API config file if it doesn't exist
  if [ ! -f "gemini_config.json" ]; then
    cat > "gemini_config.json" << EOL
{
  "api_key": "",
  "enabled": false,
  "temperature": 0.2,
  "max_output_tokens": 1024
}
EOL
    log "INFO" "Created Gemini API configuration file"
  fi
  
  # Load Gemini API key if available
  if [ -f "gemini_config.json" ]; then
    GEMINI_API_KEY=$(jq -r '.api_key' gemini_config.json)
    GEMINI_ENABLED=$(jq -r '.enabled' gemini_config.json)
    log "INFO" "Loaded Gemini API configuration"
  fi
}

# Initialize SQLite database
init_sqlite_db() {
  log "INFO" "Initializing SQLite database..."
  
  if [ -f "$DB_FILE" ]; then
    log "DEBUG" "SQLite database already exists"
    return
  fi
  
  sqlite3 "$DB_FILE" << EOF
PRAGMA busy_timeout = 5000;  -- Set timeout to 5 seconds
PRAGMA journal_mode = WAL;   -- Use Write-Ahead Logging for better concurrency

CREATE TABLE files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  filename TEXT NOT NULL,
  original_path TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE keywords (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  keyword TEXT NOT NULL,
  folder TEXT NOT NULL
);

CREATE TABLE file_keywords (
  file_id INTEGER,
  keyword_id INTEGER,
  symlink_path TEXT,
  FOREIGN KEY(file_id) REFERENCES files(id),
  FOREIGN KEY(keyword_id) REFERENCES keywords(id),
  PRIMARY KEY(file_id, keyword_id)
);

CREATE TABLE suggested_keywords (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_id INTEGER,
  keyword TEXT NOT NULL,
  confidence FLOAT NOT NULL,
  applied BOOLEAN DEFAULT 0,
  FOREIGN KEY(file_id) REFERENCES files(id)
);
EOF
  
  if [ $? -eq 0 ]; then
    log "INFO" "SQLite database created successfully"
  else
    log "ERROR" "Failed to create SQLite database"
    USE_SQLITE=false
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

# Sync rules from YAML to SQLite database
sync_rules_to_db() {
  log "DEBUG" "Syncing rules to SQLite database"
  
  # Make sure any existing transactions are ended
  sqlite3 "$DB_FILE" "COMMIT;" 2>/dev/null || true
  sqlite3 "$DB_FILE" "ROLLBACK;" 2>/dev/null || true
  
  # Add a small delay to ensure DB is released
  sleep 1
  
  # Start a transaction with timeout and better error handling
  if ! sqlite3 "$DB_FILE" "PRAGMA busy_timeout = 5000; BEGIN TRANSACTION;" 2>/dev/null; then
    log "ERROR" "Failed to begin transaction for syncing rules - database may be locked"
    echo "Database appears to be locked. Please try again later."
    return 1
  fi
  # Start a transaction with timeout
  if ! sqlite3 "$DB_FILE" "PRAGMA busy_timeout = 5000; BEGIN TRANSACTION;"; then
    log "ERROR" "Failed to begin transaction for syncing rules"
    return 1
  fi
  
  # Clear existing keywords
  if ! sqlite3 "$DB_FILE" "DELETE FROM keywords;"; then
    log "ERROR" "Failed to clear existing keywords"
    sqlite3 "$DB_FILE" "ROLLBACK;"
    return 1
  fi
  
  # Insert new keywords from rules file
  local success=true
  while read -r keyword folder; do
    # Escape single quotes
    local safe_keyword=$(echo "$keyword" | sed "s/'/''/g")
    local safe_folder=$(echo "$folder" | sed "s/'/''/g")
    
    if ! sqlite3 "$DB_FILE" "INSERT INTO keywords (keyword, folder) VALUES ('$safe_keyword', '$safe_folder');"; then
      log "ERROR" "Failed to insert keyword $keyword into database"
      success=false
      break
    fi
  done < <(parse_rules)
  
  # Commit or rollback the transaction
  if [[ "$success" == "true" ]]; then
    if ! sqlite3 "$DB_FILE" "COMMIT;"; then
      log "ERROR" "Failed to commit rules to database"
      sqlite3 "$DB_FILE" "ROLLBACK;"
      return 1
    fi
    log "INFO" "Rules synced to database"
  else
    sqlite3 "$DB_FILE" "ROLLBACK;"
    log "ERROR" "Failed to sync rules to database, changes rolled back"
    return 1
  fi
  
  return 0
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

# Add file to SQLite database
add_file_to_db() {
  local filename="$1"
  local filepath="$2"
  local symlinks=("${@:3}")  # Additional arguments are symlinks

  # Escape single quotes in filename and filepath
  local safe_filename=$(echo "$filename" | sed "s/'/''/g")
  local safe_filepath=$(echo "$filepath" | sed "s/'/''/g")

  # Start a transaction
  sqlite3 "$DB_FILE" "BEGIN TRANSACTION;"

  # Check if file exists in database
  file_exists=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM files WHERE original_path='$safe_filepath';")

  if [[ "$file_exists" -eq 0 ]]; then
    # Insert new file
    if ! sqlite3 "$DB_FILE" "INSERT INTO files (filename, original_path) VALUES ('$safe_filename', '$safe_filepath');"; then
      log "ERROR" "Failed to add file to database: $filename"
      sqlite3 "$DB_FILE" "ROLLBACK;"
      return 1
    fi
    log "DEBUG" "Added new file to database: $filename"
  else
    # Update existing file (timestamp will update automatically)
    if ! sqlite3 "$DB_FILE" "UPDATE files SET filename='$safe_filename' WHERE original_path='$safe_filepath';"; then
      log "ERROR" "Failed to update file in database: $filename"
      sqlite3 "$DB_FILE" "ROLLBACK;"
      return 1
    fi
    log "DEBUG" "Updated existing file in database: $filename"
  fi

  # Get the file ID
  file_id=$(sqlite3 "$DB_FILE" "SELECT id FROM files WHERE original_path='$safe_filepath';")

  # Insert symlinks
  for symlink in "${symlinks[@]}"; do
    local safe_symlink=$(echo "$symlink" | sed "s/'/''/g")
    if ! sqlite3 "$DB_FILE" "INSERT INTO file_keywords (file_id, symlink_path) VALUES ($file_id, '$safe_symlink');"; then
      log "ERROR" "Failed to add symlink to database: $symlink"
      sqlite3 "$DB_FILE" "ROLLBACK;"
      return 1
    fi
    log "DEBUG" "Added symlink to database: $symlink"
  done

  # Commit the transaction
  if ! sqlite3 "$DB_FILE" "COMMIT;"; then
    log "ERROR" "Failed to commit transaction"
    sqlite3 "$DB_FILE" "ROLLBACK;"
    return 1
  fi

  return 0
}

# API connection to Gemini for additional keyword extraction
gemini_analyze() {
  log "INFO" "Starting Gemini API analysis..."
  
  # Check if Gemini is configured
  if [[ -z "$GEMINI_API_KEY" || "$GEMINI_ENABLED" != "true" ]]; then
    log "WARN" "Gemini API is not configured. Please edit gemini_config.json"
    echo "Gemini API is not configured. Please set your API key in gemini_config.json."
    echo "Press any key to continue..."
    read -n 1
    return
  fi
  
  # Get temperature and max tokens from config
  temperature=$(jq -r '.temperature' gemini_config.json)
  max_tokens=$(jq -r '.max_output_tokens' gemini_config.json)
  
  # Count files for reporting
  total_files=$(find "$ORIGINALS_DIR" -type f -name "*.md" | wc -l)
  if [[ $total_files -eq 0 ]]; then
    log "WARN" "No markdown files found in $ORIGINALS_DIR"
    echo "No markdown files found in $ORIGINALS_DIR. Please add some files first."
    echo "Press any key to continue..."
    read -n 1
    return
  fi
  
  processed=0
  
  # Process each markdown file
  find "$ORIGINALS_DIR" -type f -name "*.md" | while read -r file; do
    filename=$(basename "$file")
    processed=$((processed + 1))
    log "INFO" "Analyzing file $processed/$total_files with Gemini API: $filename"
    echo "Analyzing file $processed/$total_files: $filename"
    
    # Get file content
    content=$(cat "$file")
    
    # Prepare API request payload
    payload=$(cat <<EOF
{
  "contents": [
    {
      "parts": [
        {
          "text": "Extract 3-5 relevant keywords from the following text. Return only a JSON array of strings with the keywords, nothing else:\n\n$content"
        }
      ]
    }
  ],
  "generationConfig": {
    "temperature": $temperature,
    "maxOutputTokens": $max_tokens
  }
}
EOF
)
    
    # Make API request
    response=$(curl -s -H "Content-Type: application/json" -H "Authorization: Bearer $GEMINI_API_KEY" -d "$payload" "$GEMINI_API_URL")
    
    # Check for errors
    if echo "$response" | jq -e '.error' > /dev/null; then
      error_msg=$(echo "$response" | jq -r '.error.message')
      log "ERROR" "Gemini API error: $error_msg"
      echo "Error from Gemini API: $error_msg"
      continue
    fi
    
    # Extract keywords from response
    suggested_keywords=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text' | jq -r '.[]' 2>/dev/null)
    
    if [[ -z "$suggested_keywords" ]]; then
      log "WARN" "No keywords suggested by Gemini for $filename"
      echo "No keywords suggested for $filename"
      continue
    fi
    
    # Get file ID if using SQLite
    if [[ "$USE_SQLITE" == "true" ]]; then
      file_id=$(sqlite3 "$DB_FILE" "SELECT id FROM files WHERE filename='$filename';")
      
      if [[ -z "$file_id" ]]; then
        realpath_file=$(realpath "$file")
        add_file_to_db "$filename" "$realpath_file"
        file_id=$(sqlite3 "$DB_FILE" "SELECT id FROM files WHERE original_path='$realpath_file';")
      fi
      
      # Start a transaction for this file's operations
      sqlite3 "$DB_FILE" "PRAGMA busy_timeout = 5000; BEGIN TRANSACTION;"
      
      # Clear old suggestions
      sqlite3 "$DB_FILE" "DELETE FROM suggested_keywords WHERE file_id=$file_id;"
      
      # Process each suggested keyword as a separate operation
      echo "$suggested_keywords" | while read -r keyword; do
        if [[ -n "$keyword" ]]; then
          # Escape single quotes
          safe_keyword=$(echo "$keyword" | sed "s/'/''/g")
          
          log "INFO" "Gemini suggested keyword for $filename: $keyword"
          echo "  Suggested keyword: $keyword"
          
          # Add with confidence value
          sqlite3 "$DB_FILE" "INSERT INTO suggested_keywords (file_id, keyword, confidence) VALUES ($file_id, '$safe_keyword', 0.95);"
        fi
      done
      
      # Commit the transaction
      if ! sqlite3 "$DB_FILE" "COMMIT;"; then
        log "ERROR" "Failed to commit Gemini analysis results for $filename"
        sqlite3 "$DB_FILE" "ROLLBACK;"
      fi
    fi
  done
  
  echo "Gemini analysis complete. Processed $total_files files."
  echo "You can review and apply suggested keywords in the menu."
  echo "Press any key to continue..."
  read -n 1
}

# Repair SQLite database if it's corrupted
repair_database() {
  log "INFO" "Attempting to repair SQLite database..."
  
  # Create a backup of the current database
  if [ -f "$DB_FILE" ]; then
    cp "$DB_FILE" "${DB_FILE}.bak"
    log "INFO" "Created database backup: ${DB_FILE}.bak"
  else
    log "ERROR" "Database file doesn't exist, nothing to repair"
    return 1
  fi
  
  # Try to repair using SQLite's integrity check
  integrity_check=$(sqlite3 "$DB_FILE" "PRAGMA integrity_check;")
  
  if [[ "$integrity_check" == "ok" ]]; then
    log "INFO" "Database integrity check passed"
    
    # Try vacuum to defragment
    if sqlite3 "$DB_FILE" "VACUUM;"; then
      log "INFO" "Database vacuumed successfully"
    else
      log "WARN" "Failed to vacuum database"
    fi
    
    echo "Database integrity verified and optimized."
  else
    log "WARN" "Database integrity check failed: $integrity_check"
    
    # Export and reimport all data
    echo "Database needs repair. Attempting to recover data..."
    
    # Create a temporary directory
    tmp_dir=$(mktemp -d)
    
    # Export all tables to CSV
    for table in files keywords file_keywords suggested_keywords; do
      sqlite3 "$DB_FILE" ".mode csv" ".output $tmp_dir/$table.csv" "SELECT * FROM $table;"
    done
    
    # Export all tables to JSON
    for table in files keywords file_keywords suggested_keywords; do
      sqlite3 "$DB_FILE" ".mode json" ".output $tmp_dir/$table.json" "SELECT * FROM $table;"
    done
    
    # Export all tables to YAML
    for table in files keywords file_keywords suggested_keywords; do
      sqlite3 "$DB_FILE" ".mode json" ".output $tmp_dir/$table.json" "SELECT * FROM $table;"
      yq eval -P "$tmp_dir/$table.json" > "$tmp_dir/$table.yaml"
    done
    
    # Create a new database
    rm "$DB_FILE"
    init_sqlite_db
    
    # Import data back
    for table in files keywords file_keywords suggested_keywords; do
      if [ -f "$tmp_dir/$table.csv" ]; then
        sqlite3 "$DB_FILE" ".mode csv" ".import $tmp_dir/$table.csv $table"
      fi
    done
    
    # Clean up
    rm -rf "$tmp_dir"
    
    log "INFO" "Database repair attempt completed"
    echo "Database repair attempt completed. If issues persist, consider restoring from backup."
  fi
  
  echo "Press any key to continue..."
  read -n 1
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
    echo "6. Run Gemini analysis"
    echo "7. Review suggested keywords"
    echo "8. View dictionary"
    echo "9. Configure Gemini API"
    echo "10. Toggle SQLite/YAML storage (current: $(if [[ "$USE_SQLITE" == "true" ]]; then echo "SQLite"; else echo "YAML"; fi))"
    echo "11. Toggle debug mode (current: $(if [[ "$DEBUG" == "true" ]]; then echo "ON"; else echo "OFF"; fi))"
    echo "12. View log file"
    echo "13. Repair database"
    echo "14. Create all keyword folders"
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
      6) gemini_analyze ;;
      7) review_suggestions ;;
      8) view_dictionary ;;
      9) configure_gemini ;;
      10) toggle_storage ;;
      11) toggle_debug ;;
      12) view_log ;;
      13) repair_database ;;
      14) create_keyword_folders ;;
      15) schedule_daily_processing ;;
      q|Q) echo "Goodbye!"; exit 0 ;;
      *) echo "Invalid option. Press any key to continue..."; read -n 1 ;;
    esac
  done
}

diagnose_db() {
  echo "=== DATABASE DIAGNOSTICS ==="
  echo "Database file: $DB_FILE"
  
  if [ ! -f "$DB_FILE" ]; then
    echo "ERROR: Database file does not exist!"
    return 1
  fi
  
  echo "File size: $(du -h "$DB_FILE" | cut -f1)"
  echo "Permissions: $(ls -l "$DB_FILE")"
  
  echo -e "\n== Table Counts =="
  echo "Files: $(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM files;")"
  echo "Keywords: $(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM keywords;")"
  echo "File-Keyword Relationships: $(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM file_keywords;")"
  echo "Suggested Keywords: $(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM suggested_keywords;")"
  
  echo -e "\n== Sample Data =="
  echo "Sample Files:"
  sqlite3 "$DB_FILE" "SELECT id, filename, original_path FROM files LIMIT 5;"
  
  echo -e "\nSample Keywords:"
  sqlite3 "$DB_FILE" "SELECT id, keyword, folder FROM keywords LIMIT 5;"
  
  echo -e "\nSample File-Keyword Relationships:"
  sqlite3 "$DB_FILE" "SELECT file_id, keyword_id, symlink_path FROM file_keywords LIMIT 5;"
  
  echo -e "\n== Orphaned Relationships =="
  echo "File IDs in file_keywords that don't exist in files:"
  sqlite3 "$DB_FILE" "SELECT DISTINCT file_id FROM file_keywords WHERE file_id NOT IN (SELECT id FROM files);"
  
  echo "Keyword IDs in file_keywords that don't exist in keywords:"
  sqlite3 "$DB_FILE" "SELECT DISTINCT keyword_id FROM file_keywords WHERE keyword_id NOT IN (SELECT id FROM keywords);"
  
  echo -e "\n=== END DIAGNOSTICS ==="
}

# Review and apply suggested keywords from Gemini
review_suggestions() {
  if [[ "$USE_SQLITE" != "true" ]]; then
    echo "This feature requires SQLite to be enabled."
    echo "Press any key to continue..."
    read -n 1
    return
  fi
  
  # Check if there are any suggestions
  suggestions_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM suggested_keywords WHERE applied=0;")
  
  if [[ "$suggestions_count" -eq 0 ]]; then
    echo "No pending keyword suggestions found."
    echo "Run Gemini analysis first to get suggestions."
    echo "Press any key to continue..."
    read -n 1
    return
  fi
  
  # Get files with suggestions
  files_with_suggestions=$(sqlite3 "$DB_FILE" "
    SELECT f.id, f.filename, COUNT(s.id) as suggestion_count
    FROM files f
    JOIN suggested_keywords s ON f.id = s.file_id
    WHERE s.applied = 0
    GROUP BY f.id
    ORDER BY f.filename;
  ")
  
  if [[ -z "$files_with_suggestions" ]]; then
    echo "No pending suggestions found."
    echo "Press any key to continue..."
    read -n 1
    return
  fi
  
  # Display file selection menu
  clear
  echo "=== FILES WITH SUGGESTED KEYWORDS ==="
  echo "ID | Filename | Suggestions"
  echo "----------------------------------"
  echo "$files_with_suggestions" | while IFS="|" read -r id filename count; do
    echo "$id | $filename | $count suggestions"
  done
  echo
  echo -n "Enter file ID to review (or 0 to return): "
  read -r file_id
  
  if [[ "$file_id" -eq 0 ]]; then
    return
  fi
  
  # Check if file ID is valid
  file_exists=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM files WHERE id=$file_id;")
  
  if [[ "$file_exists" -eq 0 ]]; then
    echo "Invalid file ID."
    echo "Press any key to continue..."
    read -n 1
    return
  fi
  
  # Get file details
  filename=$(sqlite3 "$DB_FILE" "SELECT filename FROM files WHERE id=$file_id;")
  filepath=$(sqlite3 "$DB_FILE" "SELECT original_path FROM files WHERE id=$file_id;")
  
  # Get suggestions for this file
  suggestions=$(sqlite3 "$DB_FILE" "
    SELECT id, keyword, confidence
    FROM suggested_keywords
    WHERE file_id=$file_id AND applied=0
    ORDER BY confidence DESC;
  ")
  
  while true; do
    clear
    echo "=== SUGGESTED KEYWORDS FOR $filename ==="
    echo "ID | Keyword | Confidence"
    echo "----------------------------"
    echo "$suggestions" | while IFS="|" read -r sugg_id keyword confidence; do
      echo "$sugg_id | $keyword | $(printf "%.2f" $confidence)"
    done
    echo
    echo "Options:"
    echo "  a <id>    - Apply suggestion (add to file and rules)"
    echo "  i <id>    - Ignore suggestion"
    echo "  v         - View file content"
    echo "  q         - Return to main menu"
    echo
    echo -n "Enter option: "
    read -r option_type option_id
    
    case "$option_type" in
      a)
        if [[ -n "$option_id" ]]; then
          # Get keyword
          keyword=$(sqlite3 "$DB_FILE" "SELECT keyword FROM suggested_keywords WHERE id=$option_id;")
          
          if [[ -n "$keyword" ]]; then
            # Check if keyword is already in rules
            keyword_exists=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM keywords WHERE keyword='$keyword';")
            
            if [[ "$keyword_exists" -eq 0 ]]; then
              # Add to rules
              echo "$keyword: $keyword" >> "$RULES_FILE"
              log "INFO" "Added new keyword to rules: $keyword"
              
              # Add to keywords table
              sqlite3 "$DB_FILE" "INSERT INTO keywords (keyword, folder) VALUES ('$keyword', '$keyword');"
            fi
            
            # Add keyword to file if not already there
            if ! grep -q "{{$keyword}}" "$filepath"; then
              echo -e "\n{{$keyword}}" >> "$filepath"
              log "INFO" "Added keyword {{$keyword}} to $filename"
            fi
            
            # Mark as applied
            sqlite3 "$DB_FILE" "UPDATE suggested_keywords SET applied=1 WHERE id=$option_id;"
            
            # Process the file again to create symlinks
            process_files
            
            # Refresh suggestions list
            suggestions=$(sqlite3 "$DB_FILE" "
              SELECT id, keyword, confidence
              FROM suggested_keywords
              WHERE file_id=$file_id AND applied=0
              ORDER BY confidence DESC;
            ")
            
            echo "Applied keyword: $keyword"
            echo "Press any key to continue..."
            read -n 1
          fi
        fi
        ;;
      i)
        if [[ -n "$option_id" ]]; then
          # Mark as applied without doing anything
          sqlite3 "$DB_FILE" "UPDATE suggested_keywords SET applied=1 WHERE id=$option_id;"
          
          # Refresh suggestions list
          suggestions=$(sqlite3 "$DB_FILE" "
            SELECT id, keyword, confidence
            FROM suggested_keywords
            WHERE file_id=$file_id AND applied=0
            ORDER BY confidence DESC;
          ")
          
          echo "Ignored suggestion."
          echo "Press any key to continue..."
          read -n 1
        fi
        ;;
      v)
        clear
        echo "=== FILE CONTENT: $filename ==="
        echo
        cat "$filepath"
        echo
        echo "Press any key to continue..."
        read -n 1
        ;;
      q)
        return
        ;;
      *)
        echo "Invalid option."
        echo "Press any key to continue..."
        read -n 1
        ;;
    esac
    
    # If no more suggestions, exit
    if [[ -z "$suggestions" ]]; then
      echo "No more suggestions for this file."
      echo "Press any key to continue..."
      read -n 1
      return
    fi
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
    echo "Enter new location (or press Enter to use default: ~/Documents/Zettelkatsen/originals):"
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
DB_FILE: "$DB_FILE"
LOG_FILE: "$LOG_FILE"
DEFAULT_EDITOR: "${DEFAULT_EDITOR}"

# Settings
USE_SQLITE: $USE_SQLITE
DEBUG: $DEBUG

# API Settings
GEMINI_API_KEY: "$GEMINI_API_KEY"
GEMINI_API_URL: "$GEMINI_API_URL"
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
        DB_FILE=$(grep "^DB_FILE:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        LOG_FILE=$(grep "^LOG_FILE:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        DEFAULT_EDITOR=$(grep "^DEFAULT_EDITOR:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        USE_SQLITE=$(grep "^USE_SQLITE:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        DEBUG=$(grep "^DEBUG:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        GEMINI_API_KEY=$(grep "^GEMINI_API_KEY:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        GEMINI_API_URL=$(grep "^GEMINI_API_URL:" "$variables_file" | cut -d ":" -f2- | sed 's/^[ \t]*//')
        
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
