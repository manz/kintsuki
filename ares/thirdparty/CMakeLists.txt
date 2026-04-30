add_library(sljit STATIC sljit/sljit_src/sljitLir.c)

target_include_directories(sljit PUBLIC ../thirdparty)
target_compile_definitions(sljit PUBLIC SLJIT_HAVE_CONFIG_PRE=1 SLJIT_HAVE_CONFIG_POST=1)
target_compile_options(sljit PRIVATE $<$<COMPILE_LANG_AND_ID:C,AppleClang,Clang,GNU>:-Wno-conditional-uninitialized>)

set_target_properties(sljit PROPERTIES FOLDER thirdparty PREFIX "")

# kintsuki strips libchdr (CD-ROM), ymfm (Yamaha FM), TZXFile (ZX tape),
# and qon (BML serializer) — none used by the SNES core.
