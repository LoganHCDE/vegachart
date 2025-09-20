from flask import Flask, request, jsonify, send_file, send_from_directory, g
from flask_cors import CORS
import io
import os
import sys
import tempfile
import re
import logging
import traceback
import subprocess
import matplotlib
import psycopg2
import matplotlib.colors as mcolors
from psycopg2 import pool

matplotlib.use('Agg')
import matplotlib.pyplot as plt

# --- Configuration ---
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__, static_folder='.', static_url_path='')
CORS(app)

# --- Database Connection Pool ---
# Fly.io provides the DATABASE_URL environment variable automatically when you attach a Postgres db
try:
    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        logger.warning("DATABASE_URL not set. Database features will not work.")
        postgreSQL_pool = None
    else:
        postgreSQL_pool = psycopg2.pool.SimpleConnectionPool(1, 20, dsn=db_url)
        logger.info("Database connection pool created.")
except (Exception, psycopg2.Error) as error:
    logger.error("Error while connecting to PostgreSQL", error)
    postgreSQL_pool = None

def get_db():
    """Opens a new database connection if there is none yet for the current application context."""
    if 'db' not in g:
        if postgreSQL_pool:
            g.db = postgreSQL_pool.getconn()
        else:
            g.db = None
    return g.db

@app.teardown_appcontext
def close_db(e=None):
    """Closes the database again at the end of the request."""
    db = g.pop('db', None)
    if db is not None and postgreSQL_pool:
        postgreSQL_pool.putconn(db)

# --- Chart Generation Logic (largely unchanged) ---

R_EXECUTABLE = 'Rscript' # The Dockerfile will ensure this is in the PATH

def execute_python_code(code, csv_data=None, bg_choice: str | None = None):
    # This function remains the same as your original
    try:
        img_buffer = io.BytesIO()
        # Configure save behavior based on background choice
        transparent = True if (bg_choice == 'transparent') else False
        # Ensure we propagate the figure facecolor to the saved image and allow transparency when requested
        save_repl = f'plt.savefig(img_buffer, format="png", bbox_inches="tight", dpi=150, facecolor=plt.gcf().get_facecolor(), edgecolor="none", transparent={str(transparent)})\nplt.close()'
        modified_code = code.replace('plt.show()', save_repl)
        if csv_data:
            pd_read_csv_pattern = r'pd\.read_csv\s*\(\s*[\'"][^\'\"]*[\'"](?:\s*,\s*[^)]*)??\s*\)'
            csv_replacement = 'pd.read_csv(io.StringIO(csv_data_string))'
            modified_code = re.sub(pd_read_csv_pattern, csv_replacement, modified_code)
            import_lines = []
            code_lines = modified_code.split('\n')
            insert_index = 0
            for i, line in enumerate(code_lines):
                stripped = line.strip()
                if stripped.startswith('import ') or stripped.startswith('from '):
                    insert_index = i + 1
                elif stripped and not stripped.startswith('#'):
                    break
            if 'import io' not in modified_code:
                code_lines.insert(insert_index, 'import io')
                insert_index += 1
            code_lines.insert(insert_index, f'csv_data_string = """{csv_data}"""')
            modified_code = '\n'.join(code_lines)
        plt.clf()
        exec(modified_code)
        img_buffer.seek(0)
        return img_buffer
    except Exception as e:
        logger.error(f"Python code execution failed: {e}")
        raise

def execute_r_code(code, csv_data=None, bg_choice: str | None = None):
    # This function remains the same as your original
    with tempfile.TemporaryDirectory() as temp_dir:
        r_code_file = os.path.join(temp_dir, 'user_script.R')
        output_plot_file = os.path.join(temp_dir, 'chart.png')
        runner_script_path = os.path.join(os.path.dirname(__file__), 'run_r_script.r')

        with open(r_code_file, 'w', encoding='utf-8') as f:
            f.write(code)

        r_command = [R_EXECUTABLE, runner_script_path, r_code_file, output_plot_file]

        if csv_data:
            csv_data_file = os.path.join(temp_dir, 'data.csv')
            with open(csv_data_file, 'w', encoding='utf-8') as f:
                f.write(csv_data)
            r_command.append(csv_data_file)
        # Pass background choice to R runner (optional 4th/5th arg overall)
        if bg_choice:
            r_command.append(bg_choice)

        logger.info(f"Executing R command: {' '.join(r_command)}")
        result = subprocess.run(
            r_command,
            capture_output=True,
            text=True,
            check=False,
            timeout=60
        )
        
        if result.returncode != 0 or not os.path.exists(output_plot_file):
            error_msg = f"R script failed.\nReturn Code: {result.returncode}\nStderr: {result.stderr}\nStdout: {result.stdout}"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
        
        with open(output_plot_file, 'rb') as f:
            img_buffer = io.BytesIO(f.read())
        
        return img_buffer

# --- API Endpoints ---

@app.route('/api/generate-chart', methods=['POST'])
def generate_chart():
    # This endpoint remains the same
    data = request.get_json()
    language = data.get('language')
    code = data.get('code')
    csv_data = data.get('csvData')
    # Prefer new image background field, fallback to legacy key
    bg_choice = data.get('imgBgChoice') or data.get('bgChoice')

    try:
        if language == 'python':
            image_buffer = execute_python_code(code, csv_data, bg_choice)
        elif language == 'r':
            image_buffer = execute_r_code(code, csv_data, bg_choice)
        else:
            return jsonify({"error": "Invalid language specified"}), 400
        
        return send_file(image_buffer, mimetype='image/png')
    except Exception as e:
        logger.error(f"Chart generation failed: {traceback.format_exc()}")
        return jsonify({"error": str(e)}), 500

@app.route('/api/submit-feedback', methods=['POST'])
def submit_feedback():
    """Receives feedback from the form and saves it to the database."""
    db_conn = get_db()
    if not db_conn:
        return jsonify({"error": "Database is not configured"}), 500
    
    data = request.get_json()
    logger.info(f"Received feedback submission: {data}")
    
    try:
        cursor = db_conn.cursor()
        query = """
            INSERT INTO feedback (satisfaction, comparison, customization, bugs_experienced, support_experience, improvement_suggestions, bug_details, feature_requests, email, anything_else)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s);
        """
        cursor.execute(query, (
            data.get('satisfaction'), data.get('comparison'), data.get('customization'),
            data.get('bugs_experienced'), data.get('likeMost'), data.get('improve'),
            data.get('bugs'), data.get('features'), data.get('email'), data.get('anythingElse')
        ))
        db_conn.commit()
        cursor.close()
        return jsonify({"message": "Feedback submitted successfully!"}), 201
    except Exception as e:
        logger.error(f"Failed to insert feedback: {traceback.format_exc()}")
        return jsonify({"error": "Could not save feedback."}), 500

@app.route('/api/track-event', methods=['POST'])
def track_event():
    """A simple analytics endpoint."""
    db_conn = get_db()
    if not db_conn:
        return jsonify({"error": "Database is not configured"}), 500
    
    data = request.get_json()
    event_name = data.get('event')
    if not event_name:
        return jsonify({"error": "Event name is required"}), 400
    
    logger.info(f"Tracked event: {event_name}")
    
    try:
        cursor = db_conn.cursor()
        query = "INSERT INTO analytics_events (event_name, event_details) VALUES (%s, %s);"
        cursor.execute(query, (event_name, data))
        db_conn.commit()
        cursor.close()
        return jsonify({"message": "Event tracked"}), 200
    except Exception as e:
        logger.error(f"Failed to track event: {traceback.format_exc()}")
        return jsonify({"error": "Could not track event."}), 500
        
# --- Static File Serving ---
@app.route('/')
def index():
    return app.send_static_file('chart.html')

@app.route('/<path:filename>')
def serve_static(filename):
    return send_from_directory('.', filename)

if __name__ == '__main__':
    # This block is for local development, not for production on Fly.io
    app.run(host='0.0.0.0', port=8080, debug=True)