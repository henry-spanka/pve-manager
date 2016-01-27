include ../../../defines.mk

PERLSOURCE = 			\
	hpacucli.pm			\
	mdadm.pm

all:

.PHONY: distclean
distclean: clean

.PHONY: clean
clean:
	rm -rf *~

.PHONY: install 
install: ${PERLSOURCE}
	install -d ${PERLLIBDIR}/PVE/RaidCheck/Plugins
	install -m 0644 ${PERLSOURCE} ${PERLLIBDIR}/PVE/RaidCheck/Plugins
