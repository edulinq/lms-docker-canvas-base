FROM ruby:3.4.6-alpine3.22

ENV CANVAS_VERSION=2025-09-24.167
ENV CANVAS_TAG=release/$CANVAS_VERSION

ENV SERVER_OWNER_EMAIL=server-owner@test.edulinq.org
ENV SERVER_OWNER_NAME=server-owner
ENV SERVER_OWNER_PASS=server-owner

USER root

WORKDIR /work

# Install the base/build packages before the main dependency packages.
RUN \
    apk add --no-cache \
        # Convenience \
        bash \
        vim \
        # Base Tooling \
        build-base \
        curl \
        git \
        libidn-dev \
        libpq-dev \
        linux-headers \
        openrc \
        shared-mime-info \
        unzip \
        wget \
        xmlsec-dev \
        yaml-dev \
        # Python \
        python3 \
        py3-pip \
        # Node \
        nodejs \
        npm \
        yarn \
        # Postgres \
        postgresql17 \
        postgresql17-contrib \
        postgresql17-openrc

# Init openrc.
RUN \
    mkdir /run/openrc \
    touch /run/openrc/softlevel

# Setup Postgres
RUN \
    rc-service postgresql start \
    && su postgres -c "createuser root" \
    && su postgres -c "psql -c 'ALTER USER root WITH SUPERUSER' -d postgres" \
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
    && rc-service postgresql stop

# Fetch Canvas
RUN \
    wget --output-document canvas.zip "http://github.com/instructure/canvas-lms/zipball/${CANVAS_TAG}" \
    && unzip -q canvas.zip \
    && mv instructure-canvas* canvas-source \
    && rm canvas.zip

WORKDIR /work/canvas-source

# Install Canvas Ruby Dependencies

RUN gem install bundler:2.6.7

# TEST
RUN \
    apk add --no-cache \
        protobuf-dev

# TEST
RUN \
    (gem uninstall -a -I google-protobuf || true) \
    && gem install --platform ruby google-protobuf

RUN \
    bundle install \
    && bundle clean --force

RUN \
    ( \
        # Official documentation notes that we may have to run this twice. \
        yarn install --pure-lockfile --network-timeout 100000 --production \
        || yarn install --pure-lockfile --network-timeout 100000 --production \
    ) \
    && yarn cache clean

# Canvas env options.
ENV COMPILE_ASSETS_API_DOCS=0
ENV COMPILE_ASSETS_STYLEGUIDE=0
# See: https://github.com/instructure/canvas-lms/issues/2023
ENV COMPILE_ASSETS_BRAND_CONFIGS=0
ENV RAILS_LOAD_ALL_LOCALES=0
ENV USE_OPTIMIZED_JS=true
ENV JS_BUILD_NO_FALLBACK=1

# Setup Canvas
RUN \
    # Start the DB \
    rc-service postgresql start \
    # Copy Base Config Files \
    && for config in amazon_s3 database delayed_jobs domain dynamic_settings file_store outgoing_mail security external_migration; do cp -v config/$config.yml.example config/$config.yml; done \
    # Edit Config \
    && sed -i 's/your_password/canvas/g;/secondary:/d;/replica:/d;/canvas_readonly_user/d' config/database.yml \
    # Setup Canvas \
    && bundle exec rails canvas:compile_assets --trace \
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
    && rc-service postgresql stop \
    # Cleanup \
    && rm -rf /work/canvas-source/tmp /tmp/* \
    && yarn cache clean \
    && npm cache clean --force

# Copy Scripts
COPY ./scripts /work/scripts

ENTRYPOINT ["/work/scripts/entrypoint.sh"]
