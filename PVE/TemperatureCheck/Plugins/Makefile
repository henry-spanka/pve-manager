include ../../../defines.mk

PERLSOURCE = 			\
	hp_health.pm

all:

.PHONY: distclean
distclean: clean

.PHONY: clean
clean:
	rm -rf *~

.PHONY: install 
install: ${PERLSOURCE}
	install -d ${PERLLIBDIR}/PVE/TemperatureCheck/Plugins
	install -m 0644 ${PERLSOURCE} ${PERLLIBDIR}/PVE/TemperatureCheck/Plugins
