include ../../defines.mk

SUBDIRS=Plugins

PERLSOURCE = 			\
	Plugin.pm

all:

.PHONY: distclean
distclean: clean

.PHONY: clean
clean:
	rm -rf *~

.PHONY: install 
install: ${PERLSOURCE}
	install -d ${PERLLIBDIR}/PVE/TemperatureCheck
	install -m 0644 ${PERLSOURCE} ${PERLLIBDIR}/PVE/TemperatureCheck
	set -e && for i in ${SUBDIRS}; do ${MAKE} -C $$i $@; done
