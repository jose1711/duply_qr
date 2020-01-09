#!/bin/bash
# set -x
#
# duply_qr.sh
#
# Bash script to generate a PDF with structured QR code
# containing data needed to restore Duply backup. The result
# is supposed to be printed and stored in a safe place.
#
# Note that only the absolute minimum for a restore is exported,
# exclude/pre/post files or file comments are not part of it.
# You may consider including duply profile itself inside your
# backup to preserve # all the information.
#
# It is *strongly* recommended to make a real test of restore
# with the output printed, scanned and decoded back.
#
# The idea comes from https://github.com/intra2net/paperbackup
# and related projects.
#
# Requirements:
#  - duply (obviously)
#  - qrencode
#  - enscript
#  - ImageMagick (montage)
#  - zbar (zbarimg, zbar-tools package on Debian)
#  - ghostscript (ps2pdf)
#  - xpdf (pdftoppm, poppler-utils package on Debian)
#  - evince
#
# Limitations:
#  - Structured QR codes have a size limit and if you're using
#    large number of keys this limit may be exceeded. However
#    these situations will probably be extremely rare.
#
#                                         jose1711 @ gmail com
#
# Any feedback is welcome (please use github issues)
#
umask 077

function usage {
  cat <<HERE
Usage: $1 [-C] [-V] [-c columns] [-h] [-p] [-v symbol_version] duply_profile_name

 -C                disable tar compression, compression (xz) is enabled by default
 -V                do *not* invoke a viewer (evince) program after conversion
 -c columns        number of columns (1, 2 or 3), default: 2
 -h                this help
 -p                also include public keys in the output (disabled by default)
                   (this is normally not needed as this info can be
                   derived from private key)
 -v symbol_version QR symbol version (1..40), 20 by default. Try to increase the value
                   if you're getting "Input data too large" error

E. g. $1 -c 3 my_important_data

Directory \`my_important_data\` must exist inside ~/.duply.  
HERE
}


# defaults
columns=2
publickey_export=0
compress=1
qr_version=20
viewer=1

while getopts ":c:hCVv:" options
do
  case "${options}" in
    C) compress=0 ;;
    V) viewer=0 ;;
    c) columns=${OPTARG} ;;
    h) usage "$0"; exit 0;;
    p) publickey_export=1 ;;
    v) qr_version=${OPTARG} ;;
  esac
done

shift $((OPTIND-1))

if [ $# -ne 1 ]
then
  usage "$0"
  exit 1
fi

case "$columns" in 
  1) height=13;;
  2) height=8;;
  3) height=6;;
  *) echo "Number of columns may only be 1, 2 or 3"; exit 1;;
esac

profile="$1"

if [ ! -d ~/.duply/"${profile}" ]
then
  echo "No such duply profile!"
  exit 1
fi

for executable in duply qrencode enscript montage zbarimg ps2pdf pdftoppm
do
  which "${executable}" >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    echo "Missing dependency: ${executable}"
    exit 1
  fi

done

output_basename=${profile}-duply-profile
profileDir=~/.duply/${profile}
if [ "${compress}" -eq 1 ]
then
  tarfile=$(mktemp --suffix=.tar.xz --tmpdir=${profileDir})
  TAR="tar -b 1 --null -C $HOME --files-from=- -cvJf"
else
  tarfile=$(mktemp --suffix=.tar --tmpdir=${profileDir})
  TAR="tar -b 1 --null -C $HOME --files-from=- -cvf"
fi

qr_codes_dir=$(mktemp -d --tmpdir=${profileDir})
pdf_separated=$(mktemp -d --tmpdir=${profileDir} pdf-separatedXXX)
merged_qr_code=$(mktemp --suffix=.jpg --tmpdir=${profileDir})

function cleanup {
  echo "** Cleaning up **"
  rm -r "${qr_codes_dir}" "${pdf_separated}" "${merged_qr_code}" "${tarfile}" "${output_basename}.txt" "${output_basename}.ps" "${profileDir}"/conf_mini 2>/dev/null
}

# cleanup on exit
trap cleanup EXIT

echo "** Removing exported keys to force their recreation **"
rm "${profileDir}"/gpgkey.*.pub.asc 2>/dev/null
rm "${profileDir}"/gpgkey.*.sec.asc 2>/dev/null

echo "** Calling status to reexport the keys (this may take a while) **"
duply ${profile} status

if [ $? -ne 0 ]
then
  echo "Calling status on profile '${profile}' resulted in an error, terminating."
  exit 1
fi

echo "** Sourcing conf file and printing newly defined variables **"
diff --unchanged-line-format='' --old-line-format='' \
  <(set -o posix; set) <(set -o posix; . ~/.duply/${profile}/conf; set) | \
    grep -ve '^BASH_ARGC=' -e '^_=' -e '^BASH_ARGV=' > "${profileDir}/conf_mini"

echo "** Generating tarfile **"

if [ "${publickey_export}" -eq 1 ]
then
  (
  cd
  find .duply/${profile} -maxdepth 1 \( -name conf_mini -o -name 'gpgkey.*.pub.asc' -o -name 'gpgkey.*.sec.asc' -o -name '*.json' \) -print0 | \
    $TAR "${tarfile}"
  )
else
  (
  cd
  find .duply/${profile} -maxdepth 1 \( -name conf_mini -o -name 'gpgkey.*.sec.asc' -o -name '*.json' \) -print0 | \
    $TAR "${tarfile}"
)
fi

if [ $? -ne 0 ]
then
  echo "Error generating tar file, terminating."
  exit 1
fi

md5sum_orig=$(md5sum "${tarfile}" | awk '{print $1}')

echo "** Converting to base64 and creating a set of QR codes **"
base64 "${tarfile}" | qrencode -S -t EPS --level=H -v${qr_version} -o "${qr_codes_dir}/qr.eps"
if [ $? -ne 0 ]
then
  echo "Error generating QR code, terminating."
  exit 1
fi

echo "** Making a postscript document containing QR codes **"
echo "Duply profile data for $profile on $(hostname)" > ${profile}-duply-profile.txt

set "${qr_codes_dir}"/qr-*.eps

while :
do
  if [ $# -eq 0 ]; then break; fi
  echo -e "\x00epsf[h${height}c]{$1}"
  shift
  if [ ${columns} -ge 2 ]
  then
    if [ $# -eq 0 ]; then break; fi
    echo -e "\x00epsf[h${height}cx${height}cy-${height}c]{$1}"
    shift
  fi
  if [ ${columns} -ge 3 ]
  then
    if [ $# -eq 0 ]; then break; fi
    echo -e "\x00epsf[h${height}cx$((2*height))cy-${height}c]{$1}"
    shift
  fi
done >> ${profile}-duply-profile.txt

if [ "$compress" -eq 1 ]
then
  tarflag="J"
else
  tarflag=""
fi

cat >> ${profile}-duply-profile.txt <<HERE
To decode:
 * scan all pages into separate PNG files
 * montage scanned_page*.png -geometry +0 qr_code.png
 * zbarimg --raw qr_code.png | base64 -d | tar -C destination -xv${tarflag}kf -
   (destination will probably be ~/.duply)
 * rename conf_mini to conf and proceed with restoration (consult duply
   documentation)

 Make sure to do this test at least *once* with a real printout!
HERE

enscript -e -p ${output_basename}.ps -f Courier8 ${output_basename}.txt

echo "** Converting postscript to PDF **"
ps2pdf ${output_basename}.ps ${output_basename}.pdf
pdftoppm  ${output_basename}.pdf ${pdf_separated}/page
montage ${pdf_separated}/page* -geometry +0 ${merged_qr_code}

echo "** Reading QR code back and comparing checksum **"
md5sum_decoded=$(zbarimg --raw "${merged_qr_code}" | base64 -d | md5sum - | awk '{print $1}')
if [ "${md5sum_orig}" = "${md5sum_decoded}" ]
then
  echo "OK - md5 sum matches the original"
else
  echo "Failed! Decoded data does not match the original."
  failed_qr_code=$(mktemp --suffix=.jpg --tmpdir=${profileDir})
  mv "${merged_qr_code}" ${failed_qr_code}
  echo "Check the failed output in ${failed_qr_code}."
  exit 1
fi

if [ "${viewer}" -ne 0 ]
then
  echo "** Showing the output **"
  echo "Now is the time to send this file to a printer. Do note"
  echo "that heavy-duty printers use internal harddrives as cache"
  echo "so better avoid those if you care about security."
  evince ${output_basename}.pdf
fi

echo "** Output is in ${output_basename}.pdf **"
echo "Don't forget to delete it once you're done with the printing"
