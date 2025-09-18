# Start with an official Python slim image. 'bullseye' is a stable Debian release.
FROM python:3.11-slim-bullseye

# Set environment variables to prevent interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies, including the R interpreter and libraries needed for R packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    r-base \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libpq-dev \
    build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install the R tidyverse package (which includes ggplot2, dplyr, etc.)
# This command runs inside the R interpreter
RUN R -e "install.packages('tidyverse', repos='http://cran.rstudio.com/')"

# Set the working directory inside the container
WORKDIR /app

# Copy the Python requirements file and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of your application code into the container
COPY . .

# Tell Fly.io what port your app will listen on
EXPOSE 8080

# The command to run your Flask application using the Gunicorn production server
# Gunicorn is installed via requirements.txt
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "app:app"]