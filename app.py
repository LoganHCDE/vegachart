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
import time

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

def execute_python_code(code, csv_data=None, img_bg_choice: str | None = None, chart_bg_choice: str | None = None):
    """Execute user-provided Python plotting code and return an in-memory PNG.

    - Captures figure even if user omits plt.show().
    - Injects CSV data into pandas read_csv calls when provided.
    - Adds timing logs for timeout diagnostics.
    """
    start_ts = time.time()
    try:
        img_buffer = io.BytesIO()

        # Mapping helpers for image + chart backgrounds (separate so 'Dark' differs)
        def map_image_bg(choice: str | None):
            if not choice:
                choice = 'default'
            choice_l = choice.lower()
            return {
                'transparent': None,  # special handling
                'white': '#f3f3f3',
                'blue': '#0b1220',
                # default (dark) outer figure background matches R image dark (#0a0a0a)
                'default': '#0a0a0a'
            }.get(choice_l, '#0a0a0a')

        def map_chart_bg(choice: str | None):
            if not choice:
                choice = 'default'
            choice_l = choice.lower()
            mapping = {
                'transparent': None,
                'white': '#ffffff',
                'blue': '#8ac0db',
                'green': '#8adba5',
                'yellow': '#fee14e',
                'orange': '#fd732d',
                'purple': '#ce8adb',
                'teal': '#76d3cf',
                # For "Dark" we intentionally use a slightly lighter near-black than the figure so there is visible contrast
                'default': '#111827'
            }
            return mapping.get(choice_l, '#111827')

        figure_bg = map_image_bg(img_bg_choice)
        panel_bg = map_chart_bg(chart_bg_choice) if chart_bg_choice is not None else None

        # Build replacement snippet for plt.show(); we inject panel background just before saving
        if img_bg_choice == 'transparent':
            panel_injection = '' if panel_bg is None else f"""# Apply chart panel background if requested and not transparent
try:
    fig = plt.gcf()
    for ax in fig.get_axes():
        ax.set_facecolor('{panel_bg}')
except Exception:
    pass
"""
            save_repl = (
                "fig = plt.gcf()\n"
                "# Make outer figure transparent while keeping axes opaque\n"
                "try:\n    fig.patch.set_alpha(0.0)\nexcept Exception:\n    pass\n"
                "for ax in fig.get_axes():\n"
                "    try:\n"
                "        fc = ax.get_facecolor()\n"
                "        if isinstance(fc, tuple) and len(fc) == 4:\n"
                "            ax.set_facecolor((fc[0], fc[1], fc[2], 1.0))\n"
                "    except Exception:\n"
                "        pass\n"
                f"{panel_injection}"
                "plt.savefig(img_buffer, format=\"png\", bbox_inches=\"tight\", dpi=150, facecolor=(0,0,0,0), edgecolor=\"none\", transparent=False)\n"
                "plt.close()"
            )
        else:
            # Ensure figure background is set explicitly so downstream save uses expected color
            panel_injection = '' if panel_bg is None else f"""# Apply chart panel background if requested
try:
    fig = plt.gcf()
    for ax in fig.get_axes():
        ax.set_facecolor('{panel_bg}')
except Exception:
    pass
"""
            save_repl = (
                "fig = plt.gcf()\n"
                f"try:\n    fig.patch.set_facecolor('{figure_bg}')\nexcept Exception:\n    pass\n"
                f"{panel_injection}"
                "plt.savefig(img_buffer, format=\"png\", bbox_inches=\"tight\", dpi=150, facecolor=fig.get_facecolor(), edgecolor=\"none\", transparent=False)\n"
                "plt.close()"
            )

        SHOW_SENTINEL = 'plt.show()'
        modified_code = code if code is not None else ''
        if SHOW_SENTINEL in modified_code:
            modified_code = modified_code.replace(SHOW_SENTINEL, save_repl)
        else:
            modified_code += '\n\n# Auto-added save (no plt.show() detected)\n' + save_repl + '\n'

        if csv_data:
            # Regex to find pd.read_csv('something.csv', optional args)
            pd_read_csv_pattern = r"pd\.read_csv\s*\(\s*['\"][^'\"]*['\"](?:\s*,\s*[^)]*)??\s*\)"
            import csv
            output = io.StringIO()
            if len(csv_data) > 0:
                writer = csv.DictWriter(output, fieldnames=csv_data[0].keys())
                writer.writeheader()
                writer.writerows(csv_data)
            csv_data_string = output.getvalue()
            csv_replacement = 'pd.read_csv(io.StringIO(csv_data_string))'
            modified_code = re.sub(pd_read_csv_pattern, csv_replacement, modified_code)
            code_lines = modified_code.split('\n')
            code_lines = [line for line in code_lines if line.strip() != 'import io']
            code_lines.insert(0, 'import io')
            insert_index = 0
            for i, line in enumerate(code_lines):
                s = line.strip()
                if s.startswith('import ') or s.startswith('from '):
                    insert_index = i + 1
                elif s and not s.startswith('#'):
                    break
            code_lines.insert(insert_index, f'csv_data_string = """{csv_data_string}"""')
            modified_code = '\n'.join(code_lines)

        plt.clf()
        logger.info("[PYEXEC] Starting execution (len=%d chars)" % len(modified_code))
        # Provide img_buffer and commonly used modules in the exec environment so the
        # auto-inserted save snippet (which references img_buffer) can access them.
        exec_globals = {
            'img_buffer': img_buffer,
            '__name__': '__main__'
        }
        # It's possible user code expects pandas/numpy even if not imported due to CSV injection.
        # We don't proactively import them here to avoid masking import errors, but we *could* add
        # them later if needed.
        exec(modified_code, exec_globals)
        logger.info("[PYEXEC] Execution finished in %.3fs" % (time.time() - start_ts))

        # If nothing was written (user never created a figure), create blank figure
        if not img_buffer.getbuffer().nbytes:
            fig = plt.figure()
            fig.text(0.5, 0.5, 'No plot generated', ha='center', va='center', color='red')
            fig.savefig(img_buffer, format='png', dpi=120)
            plt.close(fig)

        img_buffer.seek(0)
        return img_buffer
    except Exception as e:
        logger.error(f"Python code execution failed after {time.time() - start_ts:.3f}s: {e}")
        raise

def execute_r_code(code, csv_data=None, img_bg_choice: str | None = None, chart_bg_choice: str | None = None, show_grid_lines: bool | None = None):
    def _strip_readr_namespace(src: str) -> str:
        readr_funcs = (
            "read_csv",
            "read_csv2",
            "read_delim",
            "read_delim2",
            "read_tsv",
            "read_table",
        )
        for func in readr_funcs:
            pattern = rf"readr::\s*{func}"
            src = re.sub(pattern, func, src, flags=re.IGNORECASE)
        return src

    code = _strip_readr_namespace(code)

    start_ts = time.time()
    with tempfile.TemporaryDirectory() as temp_dir:
        r_code_file = os.path.join(temp_dir, 'user_script.R')
        output_plot_file = os.path.join(temp_dir, 'chart.png')
        runner_script_path = os.path.join(os.path.dirname(__file__), 'run_r_script.r')

        with open(r_code_file, 'w', encoding='utf-8') as f:
            f.write(code)

        # Use --vanilla for a clean R session (no site/user profiles) to reduce variability
        r_command = [R_EXECUTABLE, '--vanilla', runner_script_path, r_code_file, output_plot_file]

        if csv_data:
            import csv
            csv_data_file = os.path.join(temp_dir, 'data.csv')
            with open(csv_data_file, 'w', newline='', encoding='utf-8') as f:
                if csv_data and len(csv_data) > 0:
                    writer = csv.DictWriter(f, fieldnames=csv_data[0].keys())
                    writer.writeheader()
                    writer.writerows(csv_data)
            r_command.append(csv_data_file)
        if img_bg_choice:
            r_command.append(img_bg_choice)
        if chart_bg_choice:
            r_command.append(chart_bg_choice)
        if show_grid_lines is not None:
            r_command.append('true' if bool(show_grid_lines) else 'false')

        logger.info(f"[REXEC] Executing R command: {' '.join(r_command)}")
        result = subprocess.run(
            r_command,
            capture_output=True,
            text=True,
            check=False,
            timeout=90,  # Allow a bit more time; reverse proxy timeout should still be enforced externally
            cwd=temp_dir
        )
        logger.info(f"[REXEC] R process finished in {time.time() - start_ts:.3f}s (rc={result.returncode})")

        if result.returncode != 0 or not os.path.exists(output_plot_file):
            # Extract and clean error message
            stderr = result.stderr.strip() if result.stderr else ""
            stdout = result.stdout.strip() if result.stdout else ""

            # Try to extract the most relevant error from stderr
            error_lines = stderr.split('\n') if stderr else []
            # Look for lines that contain actual error messages (not just the script path)
            relevant_errors = [line for line in error_lines if line.strip() and not line.startswith('Execution halted') and 'Error' in line or 'error' in line.lower()]

            if relevant_errors:
                # Use the first relevant error line
                clean_error = relevant_errors[0].strip()
            elif stderr:
                # Fallback to first non-empty line of stderr, truncated
                clean_error = error_lines[0].strip()[:200] if error_lines else "Unknown R error"
            else:
                clean_error = "R script execution failed"

            # Truncate if too long
            if len(clean_error) > 300:
                clean_error = clean_error[:300] + "..."

            # Add context if output file wasn't created
            if not os.path.exists(output_plot_file):
                clean_error += " (no output image generated)"

            # Provide actionable guidance if ggplot2 is missing
            if 'there is no package called' in clean_error.lower() and 'ggplot2' in clean_error.lower():
                clean_error += " - ggplot2 isn't available in the runtime. If running locally, install R and ggplot2. If on Heroku with Docker, ensure the Docker image installs ggplot2 and redeploy."

            error_msg = f"R execution error: {clean_error}"
            logger.error(f"[REXEC] R script failed after {time.time() - start_ts:.3f}s rc={result.returncode}. Full stderr: {stderr[:500]}...")
            raise RuntimeError(error_msg)

        with open(output_plot_file, 'rb') as f:
            img_buffer = io.BytesIO(f.read())

        logger.info(f"[REXEC] Successfully generated image in {time.time() - start_ts:.3f}s size={len(img_buffer.getvalue())} bytes")
        return img_buffer

# --- API Endpoints ---

@app.route('/api/generate-chart', methods=['POST'])
def generate_chart():
    # This endpoint remains the same
    data = request.get_json()
    language = data.get('language')
    code = data.get('code')
    csv_data = data.get('data')
    # Prefer new image background field, fallback to legacy key
    img_bg_choice = data.get('imgBgChoice') or data.get('bgChoice')
    chart_bg_choice = data.get('chartBgChoice')
    show_grid_lines = data.get('showGridLines')

    try:
        if language == 'python':
            image_buffer = execute_python_code(code, csv_data, img_bg_choice, chart_bg_choice)
        elif language == 'r':
            image_buffer = execute_r_code(code, csv_data, img_bg_choice, chart_bg_choice, show_grid_lines)
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



@app.route('/about')
def about_page():
    return app.send_static_file('about.html')


@app.route('/guide')
def guide_page():
    return app.send_static_file('guide.html')


@app.route('/feedback')
def feedback_page():
    return app.send_static_file('feedback.html')

@app.route('/<path:filename>')
def serve_static(filename):
    return send_from_directory('.', filename)

if __name__ == '__main__':
    # This block is for local development, not for production on Fly.io
    app.run(host='0.0.0.0', port=8080, debug=True)


