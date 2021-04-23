#!/usr/bin/env bash

# Copyright 2021 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This generates GCP IAM roles based on the following YAML spec:
#
#   # role name, e.g.
#   name: "foo.bar"
#   # human readable title for the role, e.g.
#   title: "Foo Barrer"
#   # human readable description for the role, e.g. 
#   description: "Allows doing Bar on Foo resources"
#   # include permissions from the following...
#   include:
#     # a list of permissions, e.g.
#     permissions:
#     - foo.bar.doSomething
#     # a list of roles, e.g.
#     roles:
#     - roles/foo.bar
#     # only include permissions matching any extended regex in this list, e.g.
#     permissionRegxes:
#     - ^foo.bar.(get|list)
#   exclude:
#     # exclude any permissions matching any extended regex in this list, e.g.
#     permissionRegexes:
#     - SuperDangerousOperation$
#
# Roles are saved to `${name}.yaml` files intended for comparison with yaml
# dumped by gcloud, or creation via gcloud, e.g.
# 
#   gcloud iam roles describe roles/foo --format=yaml | yq -y 'del(.etag)' > foo.yaml
#   generate-role-yaml.sh specs/foo.bar.yaml
#   diff foo.yaml foo.bar.yaml
#   gcloud iam roles create --project project-id foo.bar --file foo.bar.yaml
#
# Note it's possible to generate a custom role that is too large:
#
#   "The total size of the title, description, and permission names for a
#    custom role is limited to 64 KB"
#
#   ref: https://cloud.google.com/iam/docs/creating-custom-roles

set -o errexit
set -o nounset
set -o pipefail

repo_root=$(git rev-parse --show-toplevel)
script_dir=$(dirname "${BASH_SOURCE[0]}")
script_name=$(basename "${BASH_SOURCE[0]}")
input_dir="${script_dir}/specs"
output_dir="${script_dir}"

function usage() {
    echo "usage: ${script_name} [path...]" > /dev/stderr
    echo "example:" > /dev/stderr
    echo "  ${script_name} # all roles defined in ${input_dir}" > /dev/stderr
    echo "  ${script_name} ${input_dir}/spec/foo.bar.yaml # just do one" > /dev/stderr
    echo > /dev/stderr
}

function output_role_yaml() {
  local spec="${1}"

  local title description name include_roles include_permissions include_regex exclude_regex
  title=$(<"${spec}" yq -r .title)
  description=$(<"${spec}" yq -r .description)
  name=$(<"${spec}" yq -r .name)
  mapfile -t include_roles < <(<"${spec}" yq -r '.include? | .roles//[] | .[]')
  mapfile -t include_permissions < <(<"${spec}" yq -r '.include? | .permissions//[] | .[]')
  # wrap regexes in their own groups
  include_regex=$(<"${spec}" yq -r '.include? | .permissionRegexes//[] | map("(\(.))") | join("|")')
  exclude_regex=$(<"${spec}" yq -r '.exclude? | .permissionRegexes//[] | map("(\(.))") | join("|")')

  local output_path="${output_dir}/${name}.yaml"

  echo "generating custom role, spec: ${spec}, output: ${output_path}"
  (
    echo "#### generated by ${script_name} from ${spec}"
    echo "#"
    <"${spec}" sed -e 's/^/# /'
    echo "#"

    # fields are output in alphabetal order to match output from gcloud
    echo "description: ${description}"
    echo "includedPermissions:"
    (
      for permission in "${include_permissions[@]}"; do
        echo "${permission}"
      done
      for role in "${include_roles[@]}"; do
        gcloud iam roles describe "${role}" --format="yaml(includedPermissions)" | tail -n +2
      # strip list prefixes so regexes match permission name as full line
      done | sed -e 's/^- //'
    ) | sort | uniq | \
      grep    -E "${include_regex:-""}" | \
      grep -v -E "${exclude_regex:-'^$'}" | \
      sed -e 's/^/  - &/'
    echo "name: ${name}"
    echo "stage: GA"
    echo "title: ${title}"
  ) > "${output_path}"
}

if ! command -v yq &>/dev/null; then
  echo >/dev/stderr "yq not found. Please install with pip3 install -r ${repo_root}/requirements.txt"
  return 1
fi

if [ $# = 0 ]; then
    # default to everything under our input dir
    set -- "${input_dir}"
fi

for path; do
  for f in $(find ${path} -type f -name '*.yaml' | sort); do
    output_role_yaml "${f}"
  done
done
