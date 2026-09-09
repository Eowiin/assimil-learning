#!/usr/bin/env bash
#
# Convertit audio-source/ (mp3 320k stéréo, pochette embarquée) en audio-build/
# (AAC 64k mono, normalisé, sans métadonnées) prêt à embarquer dans l'app.
#
# - supprime la pochette JPEG présente dans chaque fichier (~270 Ko pour 4 s d'audio)
# - normalise le volume à -16 LUFS en gain linéaire : les niveaux source varient de
#   ~8 dB d'une phrase à l'autre, ce qui s'entend en écoute enchaînée
# - normalise le préfixe ST -> T (leçons 6, 48 et 58 nomment leur exercice ST au lieu de T)
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/audio-source"
DST="$ROOT/Resources/audio"
JOBS="${JOBS:-8}"

command -v ffmpeg >/dev/null || { echo "ffmpeg requis" >&2; exit 1; }
[ -d "$SRC" ] || { echo "audio-source/ absent" >&2; exit 1; }

convert_one() {
  local in="$1"
  local lesson base out
  lesson="$(basename "$(dirname "$in")")"
  base="$(basename "$in" .mp3)"

  # Les leçons 6, 48 et 58 utilisent ST au lieu de T. Uniformisé ici pour que
  # tout l'aval (manifest, app) n'ait qu'une seule convention à connaître.
  case "$base" in
    ST*) base="T${base#ST}" ;;
  esac

  out="$DST/$lesson/$base.m4a"
  mkdir -p "$(dirname "$out")"
  [ -f "$out" ] && return 0

  # Passe 1 : mesure du niveau réel du fichier.
  local stats i tp lra thresh offset
  stats="$(ffmpeg -hide_banner -nostats -i "$in" \
      -af loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 \
      | sed -n '/^{/,/^}/p')"

  i="$(     printf '%s' "$stats" | sed -n 's/.*"input_i" *: *"\([^"]*\)".*/\1/p')"
  tp="$(    printf '%s' "$stats" | sed -n 's/.*"input_tp" *: *"\([^"]*\)".*/\1/p')"
  lra="$(   printf '%s' "$stats" | sed -n 's/.*"input_lra" *: *"\([^"]*\)".*/\1/p')"
  thresh="$(printf '%s' "$stats" | sed -n 's/.*"input_thresh" *: *"\([^"]*\)".*/\1/p')"
  offset="$(printf '%s' "$stats" | sed -n 's/.*"target_offset" *: *"\([^"]*\)".*/\1/p')"

  local filter="loudnorm=I=-16:TP=-1.5:LRA=11"
  # Si la mesure a abouti, on applique un gain linéaire (pas de compression
  # dynamique, qui ferait pomper des clips de 4 s).
  if [ -n "$i" ] && [ "$i" != "-inf" ] && [ -n "$offset" ]; then
    filter="$filter:measured_I=$i:measured_TP=$tp:measured_LRA=$lra"
    filter="$filter:measured_thresh=$thresh:offset=$offset:linear=true"
  fi

  # -vn retire la pochette, -map_metadata -1 les tags (certains ont un BOM invalide).
  if ffmpeg -hide_banner -loglevel error -nostdin -i "$in" \
      -af "$filter" -ar 44100 -ac 1 -c:a aac -b:a 64k \
      -vn -map_metadata -1 -movflags +faststart \
      -y "$out" 2>/dev/null; then
    return 0
  fi
  echo "ÉCHEC $in" >&2
  rm -f "$out"
  return 1
}
export -f convert_one
export DST

# Argument optionnel : motif de leçon à traiter (ex. « L001 »), sinon tout.
PATTERN="${1:-L*}"

echo "Conversion de $(find "$SRC" -path "$SRC/$PATTERN/*" -name '*.mp3' | wc -l | tr -d ' ') fichiers sur $JOBS processus…"
find "$SRC" -path "$SRC/$PATTERN/*" -name '*.mp3' -print0 \
  | xargs -0 -P "$JOBS" -I{} bash -c 'convert_one "$@"' _ {}

echo
echo "Source : $(du -sh "$SRC" | cut -f1)  ->  Build : $(du -sh "$DST" | cut -f1)"
echo "Fichiers : $(find "$DST" -name '*.m4a' | wc -l | tr -d ' ')"
