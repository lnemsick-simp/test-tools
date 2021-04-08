TMPDIR=/var/opt/enemsick/tmp \
MATRIX_LABEL=build_6.3.0BETA_ \
VAGRANT_BOX_DIR=/var/opt/enemsick/packer/boxes \
SIMP_ISO_JSON_FILES='/var/opt/enemsick/ISO/SIMP-6.3.0-BETA*.json' \
bundle exec rake simp:packer:matrix[os=el7,fips=on]
bundle exec rake simp:packer:matrix[os=el6:el7,fips=on]

