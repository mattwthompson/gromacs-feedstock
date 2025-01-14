#!/bin/bash

# gromacs > 2021 requires a non default OSX version
if [ "$(uname)" = 'Darwin' ] ; then
    export MACOSX_DEPLOYMENT_TARGET=10.13 
fi


mkdir build
cd build

## See INSTALL of gromacs distro
for ARCH in SSE2 AVX_256 AVX2_256; do
  cmake_args=(
    -DSHARED_LIBS_DEFAULT=ON
    -DBUILD_SHARED_LIBS=ON
    -DGMX_PREFER_STATIC_LIBS=NO
    -DGMX_BUILD_OWN_FFTW=OFF
    -DGMX_DEFAULT_SUFFIX=ON
    # Tests are not currently run, so do not download them
    # -DREGRESSIONTEST_DOWNLOAD=ON
    -DCMAKE_PREFIX_PATH="${PREFIX}"
    -DGMX_INSTALL_PREFIX="${PREFIX}"
    -DCMAKE_INSTALL_PREFIX="${PREFIX}"
    -DGMX_SIMD="${ARCH}"
    -DCMAKE_INSTALL_BINDIR="bin.${ARCH}"
    -DCMAKE_INSTALL_LIBDIR="lib.${ARCH}"
    -DGMX_VERSION_STRING_OF_FORK="conda-forge"
  )
  # OpenCL header on Mac is not recognized by GROMACS
  if [ "$(uname)" != 'Darwin' ] ; then
      cmake_args+=(-DGMX_GPU=OpenCL)
  fi
  if [[ "${mpi}" == "nompi" ]]; then
      cmake_args+=(-DGMX_MPI=OFF -DGMX_THREAD_MPI=ON)
  else
      cmake_args+=(-DGMX_MPI=ON)
  fi
  cmake .. "${cmake_args[@]}"
  make -j "${CPU_COUNT}"
  make install
done


#
# Build the program to identify number of AVX512 FMA units
# This will only be executed on AVX-512-capable hosts. If there
# are dual AVX-512 FMA units, it will be faster to use AVX-512 SIMD, but if
# there's only a single one we prefer AVX2_256 SIMD instead.
#

#${CXX} -O3 -mavx512f -std=c++11 \
#-DGMX_IDENTIFY_AVX512_FMA_UNITS_STANDALONE=1 \
#-DGMX_X86_GCC_INLINE_ASM=1 \
#-DSIMD_AVX_512_CXX_SUPPORTED=1 \
#-o ${PREFIX}/bin.AVX_512/identifyavx512fmaunits \
#${SRC_DIR}/src/gromacs/hardware/identifyavx512fmaunits.cpp
## Create wrapper and activation scripts
## Variable declaration from MPI script fewer changes if left in.


if [ "${mpi}" = 'nompi' ] ; then
    gmx='gmx'
else
    gmx='gmx_mpi'
fi

mkdir -p "${PREFIX}/etc/conda/activate.d"
mkdir -p "${PREFIX}/etc/conda/deactivate.d"
touch "${PREFIX}/bin/${gmx}"
chmod +x "${PREFIX}/bin/${gmx}"

# Copy the deactivate scripts for conda
cp "${RECIPE_DIR}/gromacs_deactivate.sh" "${PREFIX}/etc/conda/deactivate.d/"
cp "${RECIPE_DIR}/gromacs_deactivate.csh" "${PREFIX}/etc/conda/deactivate.d/"


# Create the activate scripts for conda

# We need to find CPU-type descriptors so we know which GROMACS SIMD flavor
# to use. On Darwin, `sysctl -a` can have lines that look like
#
# hw.optional.floatingpoint: 1
# hw.optional.mmx: 1
# hw.optional.sse: 1
# hw.optional.sse2: 1
# hw.optional.sse3: 1
# hw.optional.supplementalsse3: 1
# hw.optional.sse4_1: 1
# hw.optional.sse4_2: 1
# hw.optional.x86_64: 1
# hw.optional.aes: 1
# hw.optional.avx1_0: 1
# hw.optional.rdrand: 1
# hw.optional.f16c: 1
# hw.optional.enfstrg: 1
# hw.optional.fma: 1
# hw.optional.avx2_0: 1
# hw.optional.bmi1: 1
# hw.optional.bmi2: 1
# hw.optional.rtm: 0
# hw.optional.hle: 0
# hw.optional.adx: 1
# hw.optional.mpx: 0
# hw.optional.sgx: 0
# hw.optional.avx512f: 0
# hw.optional.avx512cd: 0
# hw.optional.avx512dq: 0
# hw.optional.avx512bw: 0
# hw.optional.avx512vl: 0
# hw.optional.avx512ifma: 0
# hw.optional.avx512vbmi: 0
#
# so there we grep out lines that match that prefix and have the
# feature (indicated by the final 1). On Linux, `cat /proc/cpuinfo`
# can have lines that look like
#
# flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc art arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf pni pclmulqdq dtes64 monitor ds_cpl vmx est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand lahf_lm abm 3dnowprefetch cpuid_fault epb invpcid_single ssbd ibrs ibpb stibp ibrs_enhanced tpr_shadow vnmi flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid mpx rdseed adx smap clflushopt intel_pt xsaveopt xsavec xgetbv1 xsaves dtherm ida arat pln pts hwp hwp_notify hwp_act_window hwp_epp pku ospke md_clear flush_l1d arch_capabilities
#
# where only the available features are listed. Either way, we then use
# bash extended pattern matching to find the features we need.
case "$OSTYPE" in
    darwin*) hardware_info_command="sysctl -a | grep '^hw.optional\..*: 1$'"
             ;;
    *)       hardware_info_command="cat /proc/cpuinfo | grep -m1 '^flags'"
             ;;
esac

### Bash script (for activate and for direct access through conda run)
# Search first for AVX2, then AVX. Fall back on SSE2
{ cat <<EOF
#! /bin/bash

function _gromacs_bin_dir() {
  local arch
  arch='SSE2'
  case \$( ${hardware_info_command} ) in
    *\ avx2\ * | *avx2_0*)
      test -d "${PREFIX}/bin.AVX2_256" && \
        arch='AVX2_256'
    ;;
    *\ avx\ * | *avx1_0*)
      test -d "${PREFIX}/bin.AVX_256" && \
        arch='AVX_256'
  esac
  printf '%s' "${PREFIX}/bin.\${arch}"
}

EOF
} | tee "${PREFIX}/bin/${gmx}" > "${PREFIX}/etc/conda/activate.d/gromacs_activate.sh"

cat >> "${PREFIX}/etc/conda/activate.d/gromacs_activate.sh" <<EOF
. "\$( _gromacs_bin_dir )/GMXRC" "\${@}"
EOF

cat >> "${PREFIX}/bin/${gmx}" <<EOF
exec "\$( _gromacs_bin_dir )/${gmx}" "\${@}"
EOF

### Tcsh script (only for activate)
{ cat <<EOF
#! /bin/tcsh

setenv hwlist `${hardware_info_command}`

if ( `echo \$hwlist | grep -c 'avx512f'` > 0 && -d "${PREFIX}/bin.AVX_512" && `"${PREFIX}/bin.AVX_512/identifyavx512fmaunits" | grep -c 2` > 0 ) then
    setenv arch AVX_512
else 
    if ( `echo \$hwlist | grep -c avx2` > 0 && -d "${PREFIX}/bin.AVX2_256" ) then
        setenv arch AVX2_256
    else 
        if ( `echo \$hwlist | grep -c avx` > 0 && -d "${PREFIX}/bin.AVX_256" ) then
            setenv arch AVX_256 
        else
            setenv arch SSE2
        endif
    endif
endif

source "${PREFIX}/bin.\$arch/GMXRC"

EOF
} > "${PREFIX}/etc/conda/activate.d/gromacs_activate.csh"
