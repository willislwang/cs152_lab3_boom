#!/usr/bin/env bash

#this script is based on the firesim build toolchains script

# exit script if any command fails
set -e
set -o pipefail

DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CHIPYARD_DIR="$(dirname "$DIR")"

usage() {
    echo "usage: ${0} [OPTIONS] [riscv-tools | esp-tools | ec2fast]"
    echo ""
    echo "Installation Types"
    echo "   riscv-tools: if set, builds the riscv toolchain (this is also the default)"
    echo "   esp-tools: if set, builds esp-tools toolchain used for the hwacha vector accelerator"
    echo "   ec2fast: if set, pulls in a pre-compiled RISC-V toolchain for an EC2 manager instance"
    echo ""
    echo "Options"
    echo "   --prefix PREFIX : Install destination. If unset, defaults to $(pwd)/riscv-tools-install"
    echo "                     or $(pwd)/esp-tools-install"
    echo "   --ignore-qemu   : Ignore installing QEMU"
    echo "   --help -h       : Display this message"
    exit "$1"
}

error() {
    echo "${0##*/}: ${1}" >&2
}
die() {
    error "$1"
    exit "${2:--1}"
}

TOOLCHAIN="riscv-tools"
EC2FASTINSTALL="false"
IGNOREQEMU=""
RISCV=""

# getopts does not support long options, and is inflexible
while [ "$1" != "" ];
do
    case $1 in
        -h | --help | help )
            usage 3 ;;
        -p | --prefix )
            shift
            RISCV=$(realpath $1) ;;
        --ignore-qemu )
            IGNOREQEMU="true" ;;
        riscv-tools | esp-tools)
            TOOLCHAIN=$1 ;;
        ec2fast )
            EC2FASTINSTALL="true" ;;
        * )
            error "invalid option $1"
            usage 1 ;;
    esac
    shift
done

if [ -z "$RISCV" ] ; then
      INSTALL_DIR="$TOOLCHAIN-install"
      RISCV="$(pwd)/$INSTALL_DIR"
fi

echo "Installing toolchain to $RISCV"

# install risc-v tools
export RISCV="$RISCV"

cd "${CHIPYARD_DIR}"

SRCDIR="$(pwd)/toolchains/${TOOLCHAIN}"
[ -d "${SRCDIR}" ] || die "unsupported toolchain: ${TOOLCHAIN}"
. ./scripts/build-util.sh


if [ "${EC2FASTINSTALL}" = true ] ; then
    [ "${TOOLCHAIN}" = 'riscv-tools' ] ||
        die "unsupported precompiled toolchain: ${TOOLCHAIN}"

    echo '=>  Fetching pre-built toolchain'
    module=toolchains/riscv-tools/riscv-gnu-toolchain-prebuilt
    git config --unset submodule."${module}".update || :
    git submodule update --init --depth 1 "${module}"

    echo '==>  Verifying toolchain version hash'
    # Find commit hash without initializing the submodule
    hashsrc="$(git ls-tree -d HEAD "${SRCDIR}/riscv-gnu-toolchain" | {
        unset IFS && read -r _ type obj _ &&
        test -n "${obj}" && test "${type}" = 'commit' && echo "${obj}"
    }; )" ||
        die 'failed to obtain riscv-gnu-toolchain submodule hash' "$?"

    read -r hashbin < "${module}/HASH" ||
        die 'failed to obtain riscv-gnu-toolchain-prebuilt hash' "$?"

    echo "==>  ${hashsrc}"
    [ "${hashsrc}" = "${hashbin}" ] ||
        die "pre-built version mismatch: ${hashbin}"

    echo '==>  Installing pre-built toolchain'
    "${MAKE}" -C "${module}" DESTDIR="${RISCV}" install
    git submodule deinit "${module}" || :

else
    MAKE_VER=$("${MAKE}" --version) || true
    case ${MAKE_VER} in
        'GNU Make '[4-9]\.*)
            ;;
        'GNU Make '[1-9][0-9])
            ;;
        *)
            die 'obsolete make version; need GNU make 4.x or later'
            ;;
    esac

    module_prepare riscv-gnu-toolchain qemu
    module_build riscv-gnu-toolchain --prefix="${RISCV}" --with-cmodel=medany
    echo '==>  Building GNU/Linux toolchain'
    module_make riscv-gnu-toolchain linux
fi

module_all riscv-isa-sim --prefix="${RISCV}"
# build static libfesvr library for linking into firesim driver (or others)
echo '==>  Installing libfesvr static library'
module_make riscv-isa-sim libfesvr.a
cp -p "${SRCDIR}/riscv-isa-sim/build/libfesvr.a" "${RISCV}/lib/"

CC= CXX= module_all riscv-pk --prefix="${RISCV}" --host=riscv64-unknown-elf
module_all riscv-tests --prefix="${RISCV}/riscv64-unknown-elf"

# Common tools (not in any particular toolchain dir)

CC= CXX= SRCDIR="$(pwd)/toolchains" module_all libgloss --prefix="${RISCV}/riscv64-unknown-elf" --host=riscv64-unknown-elf

if [ -z "$IGNOREQEMU" ] ; then
SRCDIR="$(pwd)/toolchains" module_all qemu --prefix="${RISCV}" --target-list=riscv64-softmmu
fi

# make Dromajo
git submodule update --init $CHIPYARD_DIR/tools/dromajo/dromajo-src
make -C $CHIPYARD_DIR/tools/dromajo/dromajo-src/src

# create specific env.sh
cat > "$CHIPYARD_DIR/env-$TOOLCHAIN.sh" <<EOF
# auto-generated by build-toolchains.sh
export CHIPYARD_TOOLCHAIN_SOURCED=1
export RISCV=$(printf '%q' "$RISCV")
export PATH=\${RISCV}/bin:\${PATH}
export LD_LIBRARY_PATH=\${RISCV}/lib\${LD_LIBRARY_PATH:+":\${LD_LIBRARY_PATH}"}
EOF

# create general env.sh
echo "# line auto-generated by build-toolchains.sh" >> env.sh
echo "source $(printf '%q' "$CHIPYARD_DIR/env-$TOOLCHAIN.sh")" >> env.sh
echo "Toolchain Build Complete!"
