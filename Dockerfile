# Start with an official Python slim image. [cite_start]'bullseye' is a stable Debian release. [cite: 2]
[cite_start]FROM python:3.11-slim-bullseye [cite: 3]

# Set environment variables to prevent interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies, R, and pre-compiled R packages from the system repository
RUN apt-get update && apt-get install -y --no-install-recommends \
    r-base \
    r-cran-tidyverse \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libpq-dev \
    build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# [cite_start]Set the working directory inside the container [cite: 4]
WORKDIR /app

# Copy the Python requirements file and install dependencies
COPY requirements.txt .
[cite_start]RUN pip install --no-cache-dir -r requirements.txt [cite: 5]

# Copy the rest of your application code into the container
COPY . .

# [cite_start]Expose the port your app will listen on [cite: 6]
EXPOSE 8080

# The command to run your Flask application using the Gunicorn production server
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "app:app"]