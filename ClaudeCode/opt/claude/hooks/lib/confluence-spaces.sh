# shellcheck shell=bash
# Confluence space allowlist. Sourced by mcp-policy-check.sh, which checks the space a
# call names before the call is made, and by confluence-space-check.sh, which checks the
# space a page turned out to be in after it was read.

# Guard against multiple sourcing.
[[ -n "${__CONFLUENCE_SPACES_LOADED:-}" ]] && return 0
__CONFLUENCE_SPACES_LOADED=1

# --- Confluence space allowlist ----------------------------------------------
# Confluence tools are bound to these spaces, and every other space is denied. This list
# is separate from ATLASSIAN_PROJECTS because Jira project keys and Confluence space
# keys are different namespaces, so one shared list would grant a Jira project and a
# Confluence space that happen to share a key. An empty list denies every space-scoped
# Confluence call.
#
# Each entry is KEY:ID, with no spaces. Both halves are needed, because the tools do not
# agree on which one they take. getConfluenceSpace and a searchConfluence query name the
# key, and listConfluenceContent and createConfluenceContent name the numeric space id.
#
# To add a space, look its id up by opening this address in a browser while signed in to
# Confluence, with the space key in place of KEY:
#   https://mentalhealthinnovations.atlassian.net/wiki/rest/api/space/KEY
# The response is JSON. Take the top-level "id" (a number) and check that "key" and
# "name" are the space you meant. Then add KEY:ID below and a line to this table.
#
# A renamed space can answer to two names. Renaming a space in Confluence can leave the
# "key" as it was and set an "alias", which is what the space's web address then shows.
# The response carries both. This list matches names exactly, so a name is allowed only
# if it has its own entry, and a space with a key and an alias needs one entry for each,
# both with the same id. The space below is an example. After it was renamed, the
# response still gave the key APAD and the same id, with the alias PMQMS and the address
# /spaces/PMQMS, and the lookup address with PMQMS in place of KEY returned that same
# id. Whether a search accepts the alias in a space clause has not been tested.
#
#   Entry              Space name
#   PMQMS:5447614474   Product Management & QMS (alias, set when the space was renamed)
#   APAD:5447614474    The same space by its key (was AI Product & App Development)
#
# The id is held here on the assumption that Confluence keeps it fixed for the life of
# the space, which has not been checked against Atlassian's documentation. A changed id
# fails closed, because the calls that name it are then denied.
CONFLUENCE_SPACES="PMQMS:5447614474 APAD:5447614474"

# confluence_key_allowed <key>. True iff <key> (any case) is an alphanumeric space key
# with an entry in CONFLUENCE_SPACES. A personal space key (~accountId) fails the key
# shape and is denied.
confluence_key_allowed() {
  local want entry
  want="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  [[ "$want" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  for entry in $CONFLUENCE_SPACES; do
    [[ "$(printf '%s' "${entry%%:*}" | tr '[:lower:]' '[:upper:]')" == "$want" ]] && return 0
  done
  return 1
}

# confluence_space_id_allowed <id>. True iff <id> is all digits and is the id half of an
# entry in CONFLUENCE_SPACES.
confluence_space_id_allowed() {
  local entry
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  for entry in $CONFLUENCE_SPACES; do
    [[ "$entry" == *:* && "${entry#*:}" == "$1" ]] && return 0
  done
  return 1
}
