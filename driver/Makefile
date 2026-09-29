# Out-of-tree build of the Pocket EVO HL7139 charge-pump driver.
#
# This deliberately does NOT live in the kernel tree: the armada kernel already
# has an in-tree HL7139 driver for the Mangmi Pocket Max (CONFIG_CHARGER_HL7139),
# which owns drivers/power/supply/hl7139_charger.c and the "hl7139-charger"
# i2c driver name. This one is built with `make M=` so it can carry EVO-specific
# behaviour (two pumps, EVO register init) without touching that driver.
obj-m := hl7139_evo.o
