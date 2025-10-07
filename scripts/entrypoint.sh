#!/bin/bash

readonly WORK_DIR=/work/canvas-source

function main() {
    trap exit SIGINT

    cd "${WORK_DIR}"

    local exit_status=0

    # Setup

    service postgresql start
    exit_status=$?

    if [[ $exit_status -ne 0 ]] ; then
        echo "Failed to start Postgres."
        return ${exit_status}
    fi

    # Run Server

    bundle exec rails server --binding 0.0.0.0
    exit_status=$?

    # Cleanup

    service postgresql stop

    return ${exit_status}
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
