# Stage 1: Base Image with Python and System Dependencies
FROM python:3.11-slim-bullseye

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Install system dependencies and R
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       gnupg \
       dirmngr \
    # FIX: Create the keyrings directory first
    && install -m 0755 -d /etc/apt/keyrings \
    # Add the CRAN repository using the modern, secure method
    && gpg --homedir /tmp --no-default-keyring --keyring /etc/apt/keyrings/cran.gpg --keyserver keyserver.ubuntu.com --recv-keys B8F25A8A73EACF41 \
    && echo "deb [signed-by=/etc/apt/keyrings/cran.gpg] https://cloud.r-project.org/bin/linux/debian bullseye-cran40/" | tee /etc/apt/sources.list.d/cran.list \
    # Update and install R and other dependencies
    && apt-get update \
   && apt-get install -y --no-install-recommends \
     r-base \
     r-base-dev \
     gcc \
     libpq-dev \
     libcairo2-dev \
     libxt-dev \
     libpng-dev \
     libxml2-dev \
     libssl-dev \
     libcurl4-openssl-dev \
     fonts-dejavu-core \
    # Clean up
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install and verify R packages in a single, robust command
RUN Rscript -e '                                                               \
  install.packages(                                                            \
    c("ggplot2", "readr", "dplyr", "tidyr", "purrr", "stringr", "lubridate"),   \
    repos="https://cloud.r-project.org"                                        \
  );                                                                           \
  # Verification step                                                          \
  packages <- c("ggplot2", "readr", "dplyr");                                  \
  for (p in packages) {                                                        \
    if (!require(p, character.only = TRUE)) {                                  \
      cat(paste("Failed to load package:", p, "\n"));                          \
      quit(status = 1);                                                        \
    }                                                                          \
  }                                                                            \
'

# Stage 2: Application Setup
RUN useradd --create-home --shell /bin/bash appuser
WORKDIR /app

# Copy and install Python dependencies
COPY --chown=appuser:appuser requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY --chown=appuser:appuser . .
# Switch to the non-root user
USER appuser

# Expose port and define runtime command
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--timeout", "45", "app:app"]