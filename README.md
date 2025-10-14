# Data Visualization Backend

A Flask-based backend server for handling data visualization requests from the frontend index page (`./`).

## Features

- **Flask API**: Single endpoint `/generate-chart` that executes code and returns images
- **CORS Support**: Enabled for cross-origin requests from local HTML files
- **Code Execution**: Real Python and R code execution with plot generation
- **Image Response**: Returns generated plots as PNG images via HTTP
- **Error Handling**: Comprehensive error handling with proper HTTP status codes
- **Language Support**: 
  - **Python**: Executes matplotlib/seaborn code, converts `plt.show()` to image buffer
  - **R**: Executes ggplot2 code using rpy2, converts `print(p)` to `ggsave()`

## Installation

1. Navigate to the project directory:
   ```bash
   cd "c:\Users\logtu\Desktop\Vega_chart"
   ```

2. Create and activate a virtual environment (if not already done):
   ```bash
   python -m venv .venv
   .venv\Scripts\activate
   ```

3. Install required packages:
   ```bash
   pip install -r requirements.txt
   ```

## Running the Server

Start the Flask development server:
```bash
python app.py
```

The server will start on `http://127.0.0.1:5000` with debug mode enabled.

## API Endpoints

### POST `/generate-chart`

Accepts code execution requests and returns confirmation.

**Request Body:**
```json
{
    "language": "python",  // or "r"
    "code": "import matplotlib.pyplot as plt\nimport numpy as np\n\nx = np.linspace(0, 10, 100)\ny = np.sin(x)\n\nplt.figure(figsize=(10, 6))\nplt.plot(x, y)\nplt.title('Sine Wave')\nplt.show()"
}
```

**Response:**
- **Success**: Returns PNG image data directly (Content-Type: image/png)
- **Error**: Returns JSON error message with appropriate HTTP status code

**Example Error Response:**
```json
{
    "error": "Python execution failed: NameError: name 'invalid_variable' is not defined"
}
```

### GET `/health`

Health check endpoint.

**Response:**
```json
{
    "status": "healthy",
    "service": "Data Visualization Backend"
}
```

## Error Handling

The API includes proper error handling for:
- Missing JSON data
- Missing required fields (`language`, `code`)
- Invalid language values (must be "python" or "r")
- Server errors

## CORS Configuration

CORS is enabled for all origins, allowing your `./` page to communicate with the server when opened locally in a browser.

## Prerequisites

### For Python Code Execution
- Python 3.7+ with matplotlib, pandas, seaborn, numpy
- All Python dependencies are automatically installed via requirements.txt

### For R Code Execution  
- **R must be installed on the system**: Download from https://cran.r-project.org/
- **Required R packages**: Install in R with `install.packages(c("ggplot2", "dplyr", "readr", "tidyr", "purrr", "stringr", "lubridate"))`
- **Environment variable**: R_HOME must be set (usually automatic with R installation)

## Code Execution Details

### Python Code Processing
- Automatically replaces `plt.show()` with `plt.savefig()` to image buffer
- Uses matplotlib's 'Agg' backend for server environments (non-interactive)
- Returns high-quality PNG images (150 DPI)
- Supports all matplotlib/seaborn/pandas plotting functionality

### R Code Processing  
- Uses rpy2 to execute R code from Python
- Automatically appends `ggsave()` command to save plots
- Removes existing `print(p)` statements
- Requires ggplot2 object to be named 'p'
- Creates temporary files that are automatically cleaned up

## Testing

Run the test suite to verify functionality:
```bash
# Test individual functions
python test_standalone.py

# Test complete integration (starts server on port 5001)
python test_integration.py
```

## Development Notes

- Debug mode is enabled for development convenience
- CORS allows testing with local HTML files
- Comprehensive error handling for malformed code
- Automatic cleanup of temporary R plot files
- Thread-safe execution for concurrent requests
