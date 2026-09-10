# Boost through its own CMake build, shared by the iOS and Android tails
# (nix/ios/third-party.nix, nix/android/cross-overlay.nix say why nixpkgs'
# b2 build is not usable on either). The boost.io release tarball nixpkgs
# pins carries no CMakeLists.txt (checked: 1.89.0 fails "does not appear to
# contain CMakeLists.txt"), so the GitHub "-cmake" archive of the same
# version is fetched instead. Only what liblogos_core and logos-protocol
# link: process and filesystem, plus asio/system headers; their dependencies
# are pulled in by Boost's CMake automatically.
#
# The hash is the 1.89.0 archive's; a version bump has to update it.
{ fetchurl, version }:
{
  src = fetchurl {
    url = "https://github.com/boostorg/boost/releases/download/boost-${version}/boost-${version}-cmake.tar.xz";
    hash = "sha256-Z6zsAtDRGLXenrRB9ftwezoc3YhL4AyiS5pzyZVRH3Q=";
  };
  cmakeFlags = [
    "-DBOOST_INCLUDE_LIBRARIES=process;filesystem;system;asio;dll;uuid"
    "-DBOOST_INSTALL_LAYOUT=system"
    "-DBUILD_TESTING=OFF"
    "-DBOOST_ENABLE_MPI=OFF"
    "-DBOOST_ENABLE_PYTHON=OFF"
  ];
  # Boost.DLL is header-only and its CMakeLists installs nothing even when
  # listed (checked: "libraries included: ...;dll" and no boost/dll/ in
  # the prefix); logos-module-loader-qt includes it, so copy the tree.
  postInstall = ''
    cp -r ../libs/dll/include/boost/. $out/include/boost/
  '';
}
