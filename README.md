# Zettelkasten Script

A bash script for managing a Zettelkasten note-taking system with support for configuration, rules, and AI assistance.

## Overview

This script provides a command-line interface for maintaining a Zettelkasten (slip-box) knowledge management system. It helps you organize, store, and retrieve notes while maintaining connections between related ideas.

## Features

- Customizable directory structure for your notes
- Configuration management via YAML files
- Support for both SQLite and YAML-based dictionary storage
- Integration with Gemini AI API for content assistance
- Detailed logging for troubleshooting
- Customizable editor support

## Installation

1. Clone this repository:

   ```bash
   git clone https://github.com/mrhunsaker/ZettelkastenTUI.git
   cd ZettelkastenTUI
   ```

2. Make the script executable:

   ```bash
   chmod +x Zettelkasten-tui.sh
   ```

3. Run the script:

   ```bash
   ./zettelkasten-tui.sh
   ```

## Configuration

The script uses a `variables.yml` file to store configuration settings. This file is created automatically the first time you run the script, or you can create it manually.

### Default Configuration

```yaml
# Zettelkasten Configuration Variables

# Directories and Files
ORIGINALS_DIR: "~/Documents/Zettelkasten/originals"
RULES_FILE: "rules.yml"
DICTIONARY_FILE: "dictionary.yml"
DB_FILE: "zettelkasten.db"
LOG_FILE: "zettelkasten.log"
DEFAULT_EDITOR: "vim"

# Settings
USE_SQLITE: false
DEBUG: true

# API Settings
GEMINI_API_KEY: ""
GEMINI_API_URL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent"
```

### Changing Configuration

You can modify the configuration through the script's interactive menu or by directly editing the `variables.yml` file.

## Usage

When you run the script, you'll be presented with a menu of options:

1. Create new Markdown file
2. Process all files
3. Select originals directory
4. Browse by keyword
5. Edit rules file
6. Run Gemini analysis
7. Review suggested keywords
8. View dictionary
9. Configure Gemini API
10. Toggle SQLite/YAML storage (current: YAML)
11. Toggle debug mode (current: ON)
12. View log file
13. Repair database
14. Create all keyword folders
15. Schedule daily processing
q. Quit

### Creating Notes

New notes are created with a unique identifier and stored in your originals directory. You can:

- Add metadata tags
- Link to other notes
- Use templates

### Searching and Browsing

The script provides various ways to find and navigate through your notes:

- Search by keyword
- Filter by tags
- Browse by date or connections

## AI Integration

To use the Gemini AI integration:

1. Obtain an API key from Google's Gemini API
2. Add your key to the `variables.yml` file
3. Enable AI suggestions in the settings menu

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Follow the existing code style
- Add comments to explain complex logic
- Update the README with new features or changes
- Write tests for new functionality

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](http://www.apache.org/licenses/) file for details.

```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/
```

## Acknowledgments

- The Zettelkasten method was developed by Niklas Luhmann
- Inspired by various digital knowledge management systems
