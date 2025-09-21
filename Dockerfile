# Start with an official Python slim image. 'bullseye' is a stable Debian release.
FROM python:3.11-slim-bullseye

# Set environment variables to prevent interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies, R, and build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    r-base \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libpq-dev \
    build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Tidyverse and its dependencies directly from CRAN to get the latest version
RUN R -e "install.packages('tidyverse', repos='https://cloud.r-project.org')"

# Set the working directory inside the container
WORKDIR /app

# Copy the Python requirements file and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of your application code into the container
COPY . .

# Expose the port your app will listen on
EXPOSE 8080

# The command to run your Flask application using the Gunicorn production server
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "app:app"]