FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

ENV NODE_MAJOR=20

ENV RUBY_VERSION=3.4.5
ENV RUBY_SHORT_VERSION=3.4

ENV CANVAS_VERSION=2025-09-24.167
ENV CANVAS_TAG=release/$CANVAS_VERSION

ENV SERVER_OWNER_EMAIL=server-owner@test.edulinq.org
ENV SERVER_OWNER_NAME=server-owner
ENV SERVER_OWNER_PASS=server-owner

ENV BASE_USER=root
USER $BASE_USER

WORKDIR /work

# Install the base/build packages before the main dependency packages.
RUN \
    apt-get update \
    && apt-get install -y \
        # Convenience \
        vim \
        # Base Tooling \
        build-essential \
        ca-certificates \
        curl \
        git \
        gnupg \
        openssl \
        rustc \
        software-properties-common \
        unzip \
        wget \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install keys and sources.
RUN \
    # Postgres \
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' \
    && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    # Node \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    # Yarn \
    && curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \
    && echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list

# Install main dependencies.
RUN \
    apt-get update \
    && apt-get install -y \
        # Misc Deps \
        autoconf \
        libffi-dev \
        libgmp-dev \
        libidn11-dev \
        libldap2-dev \
        libpq-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        libxmlsec1-dev \
        libyaml-dev \
        zlib1g-dev \
        # Postgres \
        postgresql-14 \
        # Node \
        nodejs \
        # Yarn \
        yarn=1.19.1-1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Ruby From Source
RUN \
    wget "https://cache.ruby-lang.org/pub/ruby/${RUBY_SHORT_VERSION}/ruby-${RUBY_VERSION}.tar.gz" \
    && tar zxf "ruby-${RUBY_VERSION}.tar.gz" \
    && cd "ruby-${RUBY_VERSION}" \
    && ./configure \
    && (make || cat config.log) \
    && make install -j4 \
    && rm -rf /work/ruby*

# Setup Postgres
RUN \
    service postgresql start \
    && su postgres -c "createuser $BASE_USER" \
    && su postgres -c "psql -c 'ALTER USER $BASE_USER WITH SUPERUSER' -d postgres" \
    && psql -c "CREATE USER canvas WITH PASSWORD 'canvas'" -d postgres \
    && createdb canvas_test \
    && psql -c "GRANT ALL PRIVILEGES ON DATABASE canvas_test TO canvas" -d canvas_test \
    && psql -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO canvas" -d canvas_test \
    && psql -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO canvas" -d canvas_test \
    && createdb canvas_development \
    && psql -c "GRANT ALL PRIVILEGES ON DATABASE canvas_development TO canvas" -d canvas_development \
    && psql -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO canvas" -d canvas_development \
    && psql -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO canvas" -d canvas_development \
    && createdb canvas_production \
    && psql -c "GRANT ALL PRIVILEGES ON DATABASE canvas_production TO canvas" -d canvas_production \
    && psql -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO canvas" -d canvas_production \
    && psql -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO canvas" -d canvas_production \
    && service postgresql stop

# Fetch Canvas
RUN \
    wget --output-document canvas.zip "http://github.com/instructure/canvas-lms/zipball/${CANVAS_TAG}" \
    && unzip -q canvas.zip \
    && mv instructure-canvas* canvas-source \
    && rm canvas.zip

WORKDIR /work/canvas-source

# Install Canvas Ruby Dependencies
RUN \
   gem install bundler \
    && bundle install \
    # Official documentation notes that we may have to run this twice. \
    && (yarn install --pure-lockfile || yarn install --pure-lockfile)

# Setup Canvas
RUN \
    # Start the DB \
    service postgresql start \
    # Copy Base Config Files \
    && for config in amazon_s3 database delayed_jobs domain dynamic_settings file_store outgoing_mail security external_migration; do cp -v config/$config.yml.example config/$config.yml; done \
    # Edit Config \
    && sed -i 's/your_password/canvas/g;/secondary:/d;/replica:/d;/canvas_readonly_user/d' config/database.yml \
    # Setup Canvas \
    # See: https://github.com/instructure/canvas-lms/issues/2023 \
    && COMPILE_ASSETS_BRAND_CONFIGS=0 bundle exec rails canvas:compile_assets --trace \
    # Edit the setup script to remove user interaction. \
    && sed -i "s/email = ask.*$/email = '${SERVER_OWNER_EMAIL}'/" lib/tasks/db_load_data.rake \
    && sed -i "s/email_confirm = ask.*$/email_confirm = '${SERVER_OWNER_EMAIL}'/" lib/tasks/db_load_data.rake \
    && sed -i "s/password = ask.*$/password = '${SERVER_OWNER_PASS}'/" lib/tasks/db_load_data.rake \
    && sed -i "s/password_confirm = ask.*$/password_confirm = '${SERVER_OWNER_PASS}'/" lib/tasks/db_load_data.rake \
    && sed -i "s/name = ask.*$/name = '${SERVER_OWNER_NAME}'/" lib/tasks/db_load_data.rake \
    && sed -i "s/name_confirm = ask.*$/name_confirm = '${SERVER_OWNER_NAME}'/" lib/tasks/db_load_data.rake \
    # Setup Data \
    && CANVAS_LMS_STATS_COLLECTION=opt_out bundle exec rails db:initial_setup \
    # Stop the DB \
    && service postgresql stop

# Copy Scripts
COPY ./scripts /work/scripts

ENTRYPOINT ["/work/scripts/entrypoint.sh"]
