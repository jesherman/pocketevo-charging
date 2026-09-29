// SPDX-License-Identifier: GPL-2.0-only
/*
 * Halo Microelectronics HL7139
 *
 * Register map from:
 *   - HiSilicon hwpower GPL driver
 *   - the Mangmi Pocket Max stock kernel
 *   - the live stock device tree
 *
 */
#include <linux/bitfield.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mod_devicetable.h>
#include <linux/mutex.h>
#include <linux/pm.h>
#include <linux/power_supply.h>
#include <linux/property.h>
#include <linux/regmap.h>
#include <linux/string.h>

#define HL7139_REG_DEVICE_ID	0x00
#define  HL7139_DEV_ID_MASK	GENMASK(3, 0)
#define  HL7139_DEV_ID_HL7139	0x0a
#define  HL7139_DEV_REV_MASK	GENMASK(7, 4)

#define HL7139_REG_STATUS_A	0x05
#define  HL7139_STS_A_VIN_OVP	BIT(7)
#define  HL7139_STS_A_FAULTS	(BIT(7) | BIT(3))
#define  HL7139_STS_A_VBAT_OVP	BIT(3)
#define HL7139_REG_STATUS_B	0x06
#define  HL7139_STS_B_IIN_OCP	BIT(7)
#define  HL7139_STS_B_IBAT_OCP	BIT(6)
#define  HL7139_STS_B_CFLY_SHORT BIT(3)
#define  HL7139_STS_B_FAULTS	(BIT(7) | BIT(6) | BIT(3) | BIT(0))
#define  HL7139_STS_B_THSD	BIT(0)
#define HL7139_REG_STATUS_C	0x07
#define  HL7139_STS_C_VBUS_GOOD	BIT(0)

#define HL7139_REG_CTRL0	0x12
#define  HL7139_CTRL0_CHG_EN	BIT(7)
#define HL7139_REG_CTRL2	0x14
#define  HL7139_CTRL2_WD_DIS	BIT(3)
#define HL7139_REG_CTRL3	0x15
#define  HL7139_CTRL3_DEV_MODE	BIT(7)

#define HL7139_REG_ADC_CTRL0	0x40
#define  HL7139_ADC_READ_EN	BIT(0)
#define HL7139_REG_ADC_CTRL1	0x41

#define HL7139_REG_ADC_VIN	0x42
#define HL7139_REG_ADC_IIN	0x44
#define HL7139_REG_ADC_VBAT	0x46
#define HL7139_REG_ADC_IBAT	0x48
#define HL7139_REG_ADC_TDIE	0x4e
#define HL7139_REG_MAX		0x4f

#define HL7139_VIN_LSB_UV	4000
#define HL7139_VBAT_LSB_UV	1250
#define HL7139_IIN_CP_LSB_UA	1100
#define HL7139_IIN_BP_LSB_UA	2200
#define HL7139_IBAT_LSB_UA	2200
/* Startup/inrush window; active PPS requests are bounded separately. */
#define HL7139_STARTUP_VIN_MIN_UV	8000000
#define HL7139_STARTUP_VIN_MAX_UV	10500000
#define HL7139_SAFE_VBAT_MIN_UV	3500000
#define HL7139_SAFE_VBAT_MAX_UV	4450000
#define HL7139_SAFE_TDIE_MAX_DECI_C 900

struct hl7139 {
	struct device *dev;
	struct regmap *regmap;
	struct gpio_desc *irq_gpiod;
	struct power_supply *psy;
	struct power_supply_desc psy_desc;
	struct mutex status_lock;
	unsigned int fault_a;
	unsigned int fault_b;
};
struct hl7139_init_data {
	const struct reg_sequence *sequence;
	size_t num_sequence;
};


/*
 * Exact probe-time sequence from the Pocket EVO Android 13 factory driver
 * (hl7139_charger.ko 0.0.1_TS, build ID a5ac08ad02da5f71d).  In
 * particular, ADC control register 0x41 must be 0x08; leaving it at its
 * reset value prevented the pump from reporting or entering conversion.
 */
static const struct reg_sequence hl7139_pocket_evo_init[] = {
	{ 0x12, 0x27 },	/* charge disabled */
	{ 0x02, 0xf2 },
	{ 0x08, 0xa9 },
	{ 0x0a, 0xae },
	{ 0x0b, 0x88 },
	{ 0x0c, 0x0f },
	{ 0x0e, 0xb2 },
	{ 0x10, 0xe0 },
	{ 0x11, 0xdc },
	{ 0x13, 0x01 },
	{ 0x14, 0x08 },
	{ 0x15, 0x00 },
	{ 0x16, 0xff },
	{ 0x41, 0x08 },
	{ 0x40, 0x05 },
};
static const struct hl7139_init_data hl7139_pocket_evo_data = {
	.sequence = hl7139_pocket_evo_init,
	.num_sequence = ARRAY_SIZE(hl7139_pocket_evo_init),
};


static int hl7139_clear_irqs(struct hl7139 *chip, bool discard_faults)
{
	static const u8 read_to_clear_regs[] = {
		0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x00,
	};
	unsigned int val;
	int i, ret;

	mutex_lock(&chip->status_lock);
	for (i = 0; i < ARRAY_SIZE(read_to_clear_regs); i++) {
		ret = regmap_read(chip->regmap, read_to_clear_regs[i], &val);
		if (ret)
			goto out_unlock;
		if (!discard_faults && read_to_clear_regs[i] == HL7139_REG_STATUS_A)
			chip->fault_a |= val & HL7139_STS_A_FAULTS;
		if (!discard_faults && read_to_clear_regs[i] == HL7139_REG_STATUS_B)
			chip->fault_b |= val & HL7139_STS_B_FAULTS;
	}

	ret = 0;
out_unlock:
	mutex_unlock(&chip->status_lock);
	return ret;
}

static int hl7139_read_adc(struct hl7139 *chip, u8 reg, int lsb)
{
	u8 buf[2];
	int ret;

	ret = regmap_bulk_read(chip->regmap, reg, buf, sizeof(buf));
	if (ret)
		return ret;

	return ((buf[0] << 4) | (buf[1] & 0x0f)) * lsb;
}

static int hl7139_iin_now(struct hl7139 *chip)
{
	unsigned int ctrl3;
	int lsb, ret;

	ret = regmap_read(chip->regmap, HL7139_REG_CTRL3, &ctrl3);
	if (ret)
		return ret;

	lsb = (ctrl3 & HL7139_CTRL3_DEV_MODE) ?
		HL7139_IIN_BP_LSB_UA : HL7139_IIN_CP_LSB_UA;

	return hl7139_read_adc(chip, HL7139_REG_ADC_IIN, lsb);
}

static int hl7139_read_faults(struct hl7139 *chip, unsigned int *a,
			      unsigned int *b)
{
	int ret;

	mutex_lock(&chip->status_lock);
	ret = regmap_read(chip->regmap, HL7139_REG_STATUS_A, a);
	if (ret)
		goto out_unlock;
	ret = regmap_read(chip->regmap, HL7139_REG_STATUS_B, b);
	if (ret)
		goto out_unlock;
	chip->fault_a |= *a & HL7139_STS_A_FAULTS;
	chip->fault_b |= *b & HL7139_STS_B_FAULTS;
	*a = chip->fault_a;
	*b = chip->fault_b;

out_unlock:
	mutex_unlock(&chip->status_lock);
	return ret;
}

static int hl7139_health(struct hl7139 *chip)
{
	unsigned int a, b;
	int ret;

	ret = hl7139_read_faults(chip, &a, &b);
	if (ret)
		return ret;

	if (b & HL7139_STS_B_THSD)
		return POWER_SUPPLY_HEALTH_OVERHEAT;
	if (a & (HL7139_STS_A_VIN_OVP | HL7139_STS_A_VBAT_OVP))
		return POWER_SUPPLY_HEALTH_OVERVOLTAGE;
	if (b & (HL7139_STS_B_IIN_OCP | HL7139_STS_B_IBAT_OCP |
		 HL7139_STS_B_CFLY_SHORT))
		return POWER_SUPPLY_HEALTH_UNSPEC_FAILURE;

	return POWER_SUPPLY_HEALTH_GOOD;
}

static int hl7139_set_charge_enable(struct hl7139 *chip, bool en)
{
	unsigned int status;
	int health, tdie, vbat, vin, ret;

	if (en) {
		health = hl7139_health(chip);
		if (health < 0)
			return health;
		if (health != POWER_SUPPLY_HEALTH_GOOD)
			return -EIO;

		ret = regmap_read(chip->regmap, HL7139_REG_STATUS_C, &status);
		if (ret)
			return ret;
		if (!(status & HL7139_STS_C_VBUS_GOOD))
			return -ENOLINK;

		vin = hl7139_read_adc(chip, HL7139_REG_ADC_VIN,
					 HL7139_VIN_LSB_UV);
		if (vin < 0)
			return vin;
		if (vin < HL7139_STARTUP_VIN_MIN_UV ||
		    vin > HL7139_STARTUP_VIN_MAX_UV)
			return -ERANGE;

		vbat = hl7139_read_adc(chip, HL7139_REG_ADC_VBAT,
					  HL7139_VBAT_LSB_UV);
		if (vbat < 0)
			return vbat;
		if (vbat < HL7139_SAFE_VBAT_MIN_UV ||
		    vbat > HL7139_SAFE_VBAT_MAX_UV)
			return -ERANGE;

		tdie = hl7139_read_adc(chip, HL7139_REG_ADC_TDIE, 625);
		if (tdie < 0)
			return tdie;
		if (tdie / 1000 > HL7139_SAFE_TDIE_MAX_DECI_C)
			return -ERANGE;

		/* Preserve any fault that arrives between the gates and CHG_EN. */
		ret = hl7139_clear_irqs(chip, false);
		if (ret)
			return ret;
		health = hl7139_health(chip);
		if (health < 0)
			return health;
		if (health != POWER_SUPPLY_HEALTH_GOOD)
			return -EIO;
	}

	return regmap_update_bits(chip->regmap, HL7139_REG_CTRL0,
				  HL7139_CTRL0_CHG_EN,
				  en ? HL7139_CTRL0_CHG_EN : 0);
}

static enum power_supply_property hl7139_props[] = {
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_HEALTH,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_VOLTAGE_AVG,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_TEMP,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};

static int hl7139_get_prop(struct power_supply *psy,
			   enum power_supply_property prop,
			   union power_supply_propval *val)
{
	struct hl7139 *chip = power_supply_get_drvdata(psy);
	unsigned int reg;
	int ret;

	switch (prop) {
	case POWER_SUPPLY_PROP_PRESENT:
		ret = regmap_read(chip->regmap, HL7139_REG_STATUS_C, &reg);
		if (ret)
			return ret;
		val->intval = !!(reg & HL7139_STS_C_VBUS_GOOD);
		if (!val->intval) {
			mutex_lock(&chip->status_lock);
			chip->fault_a = 0;
			chip->fault_b = 0;
			mutex_unlock(&chip->status_lock);
		}
		return 0;
	case POWER_SUPPLY_PROP_ONLINE:
	case POWER_SUPPLY_PROP_STATUS:
		ret = regmap_read(chip->regmap, HL7139_REG_CTRL0, &reg);
		if (ret)
			return ret;
		if (prop == POWER_SUPPLY_PROP_ONLINE)
			val->intval = !!(reg & HL7139_CTRL0_CHG_EN);
		else
			val->intval = (reg & HL7139_CTRL0_CHG_EN) ?
				POWER_SUPPLY_STATUS_CHARGING :
				POWER_SUPPLY_STATUS_NOT_CHARGING;
		return 0;
	case POWER_SUPPLY_PROP_HEALTH:
		ret = hl7139_health(chip);
		if (ret < 0)
			return ret;
		val->intval = ret;
		return 0;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		ret = hl7139_read_adc(chip, HL7139_REG_ADC_VIN, HL7139_VIN_LSB_UV);
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_AVG:
		ret = hl7139_read_adc(chip, HL7139_REG_ADC_VBAT, HL7139_VBAT_LSB_UV);
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		ret = hl7139_iin_now(chip);
		break;
	case POWER_SUPPLY_PROP_TEMP:
		ret = hl7139_read_adc(chip, HL7139_REG_ADC_TDIE, 625);
		if (ret < 0)
			return ret;
		val->intval = ret / 1000;
		return 0;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "HL7139";
		return 0;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "Halo Microelectronics";
		return 0;
	default:
		return -EINVAL;
	}

	if (ret < 0)
		return ret;
	val->intval = ret;
	return 0;
}

static int hl7139_set_prop(struct power_supply *psy,
			   enum power_supply_property prop,
			   const union power_supply_propval *val)
{
	struct hl7139 *chip = power_supply_get_drvdata(psy);
	switch (prop) {
	case POWER_SUPPLY_PROP_ONLINE:
		return hl7139_set_charge_enable(chip, !!val->intval);
	default:
		return -EINVAL;
	}
}

static int hl7139_prop_writeable(struct power_supply *psy,
				 enum power_supply_property prop)
{
	switch (prop) {
	case POWER_SUPPLY_PROP_ONLINE:
		return 1;
	default:
		return 0;
	}
}

static const struct power_supply_desc hl7139_psy_desc_template = {
	.name			= "hl7139-charger",
	.type			= POWER_SUPPLY_TYPE_MAINS,
	.properties		= hl7139_props,
	.num_properties		= ARRAY_SIZE(hl7139_props),
	.get_property		= hl7139_get_prop,
	.set_property		= hl7139_set_prop,
	.property_is_writeable	= hl7139_prop_writeable,
};

static irqreturn_t hl7139_irq(int irq, void *data)
{
	struct hl7139 *chip = data;
	unsigned int a, b;

	if (hl7139_read_faults(chip, &a, &b))
		return IRQ_NONE;
	if (a & HL7139_STS_A_VIN_OVP)
		dev_warn(chip->dev, "VIN OVP\n");
	if (a & HL7139_STS_A_VBAT_OVP)
		dev_warn(chip->dev, "VBAT OVP\n");
	if (b & HL7139_STS_B_IIN_OCP)
		dev_warn(chip->dev, "IIN OCP\n");
	if (b & HL7139_STS_B_IBAT_OCP)
		dev_warn(chip->dev, "IBAT OCP\n");
	if (b & HL7139_STS_B_CFLY_SHORT)
		dev_err(chip->dev, "flying-cap short\n");
	if (b & HL7139_STS_B_THSD)
		dev_err(chip->dev, "thermal shutdown\n");

	if ((a & (HL7139_STS_A_VIN_OVP | HL7139_STS_A_VBAT_OVP)) ||
	    (b & (HL7139_STS_B_IIN_OCP | HL7139_STS_B_IBAT_OCP |
		  HL7139_STS_B_CFLY_SHORT | HL7139_STS_B_THSD)))
		regmap_update_bits(chip->regmap, HL7139_REG_CTRL0,
				   HL7139_CTRL0_CHG_EN, 0);

	power_supply_changed(chip->psy);
	return IRQ_HANDLED;
}

static bool hl7139_volatile_reg(struct device *dev, unsigned int reg)
{
	return reg <= HL7139_REG_STATUS_C || reg >= HL7139_REG_ADC_VIN;
}

static const struct regmap_config hl7139_regmap = {
	.reg_bits = 8,
	.val_bits = 8,
	.max_register = HL7139_REG_MAX,
	.volatile_reg = hl7139_volatile_reg,
	.cache_type = REGCACHE_RBTREE,
};

static const struct hl7139_init_data *hl7139_i2c_init_data(struct i2c_client *client);

static int hl7139_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct power_supply_config cfg = {};
	struct hl7139 *chip;
	const struct hl7139_init_data *init_data;
	const char *psy_name;
	unsigned int id;
	int ret;

	chip = devm_kzalloc(dev, sizeof(*chip), GFP_KERNEL);
	if (!chip)
		return -ENOMEM;
	chip->dev = dev;
	mutex_init(&chip->status_lock);
	i2c_set_clientdata(client, chip);

	chip->regmap = devm_regmap_init_i2c(client, &hl7139_regmap);
	if (IS_ERR(chip->regmap))
		return PTR_ERR(chip->regmap);

	ret = regmap_read(chip->regmap, HL7139_REG_DEVICE_ID, &id);
	if (ret)
		return dev_err_probe(dev, ret, "failed to read device id\n");
	if (FIELD_GET(HL7139_DEV_ID_MASK, id) != HL7139_DEV_ID_HL7139)
		return dev_err_probe(dev, -ENODEV,
				     "not an HL7139 (id 0x%02x)\n", id);
	dev_info(dev, "HL7139 charge pump, rev %lu\n",
		 FIELD_GET(HL7139_DEV_REV_MASK, id));

	init_data = device_get_match_data(dev);
	if (!init_data)
		init_data = hl7139_i2c_init_data(client);
	if (init_data) {
		ret = regmap_multi_reg_write(chip->regmap, init_data->sequence,
					     init_data->num_sequence);
		if (ret)
			return dev_err_probe(dev, ret,
					     "failed to initialize charge pump\n");
	}

	ret = hl7139_set_charge_enable(chip, false);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to disable charge pump\n");

	ret = hl7139_clear_irqs(chip, true);
	if (ret)
		return dev_err_probe(dev, ret, "failed to clear IRQ state\n");

	cfg.drv_data = chip;
	cfg.fwnode = dev_fwnode(dev);
	chip->psy_desc = hl7139_psy_desc_template;
	if (device_property_read_string(dev, "power-supply-name", &psy_name)) {
		psy_name = devm_kasprintf(dev, GFP_KERNEL, "hl7139-%02x",
					   client->addr);
		if (!psy_name)
			return -ENOMEM;
	}
	chip->psy_desc.name = psy_name;

	chip->psy = devm_power_supply_register(dev, &chip->psy_desc, &cfg);
	if (IS_ERR(chip->psy))
		return dev_err_probe(dev, PTR_ERR(chip->psy),
				     "failed to register power supply\n");

	chip->irq_gpiod = devm_gpiod_get_optional(dev, "intr", GPIOD_IN);
	if (IS_ERR(chip->irq_gpiod))
		return dev_err_probe(dev, PTR_ERR(chip->irq_gpiod),
				     "failed to get interrupt GPIO\n");
	if (chip->irq_gpiod) {
		client->irq = gpiod_to_irq(chip->irq_gpiod);
		if (client->irq < 0)
			return dev_err_probe(dev, client->irq,
					     "failed to map interrupt GPIO\n");
	}

	if (client->irq) {
		ret = devm_request_threaded_irq(dev, client->irq, NULL,
						hl7139_irq,
						IRQF_ONESHOT | IRQF_TRIGGER_FALLING,
						dev_name(dev), chip);
		if (ret)
			return dev_err_probe(dev, ret, "failed to request irq\n");
	}

	return 0;
}

static void hl7139_remove(struct i2c_client *client)
{
	struct hl7139 *chip = i2c_get_clientdata(client);

	if (chip)
		hl7139_set_charge_enable(chip, false);
}

static void hl7139_shutdown(struct i2c_client *client)
{
	struct hl7139 *chip = i2c_get_clientdata(client);

	if (chip)
		hl7139_set_charge_enable(chip, false);
}

/*
 * Suspend safety: a direct-charge session must not survive a suspend.
 * The charge pumps sit between VBUS and the battery with no PMIC
 * supervision of their own; leaving CHG_EN set through a suspend
 * cycle risks an uncontrolled charge path while the SoC is asleep.
 *
 * Both pumps are disabled unconditionally on suspend and left off on
 * resume. The userspace charge-policy service re-establishes a session
 * only after its full eligibility re-check (PPS contract, battery
 * voltage/temperature/SOC, pump health), so a session that was
 * interrupted by suspend is not blindly resumed.
 */
static int hl7139_suspend(struct device *dev)
{
	struct hl7139 *chip = dev_get_drvdata(dev);
	unsigned int ctrl0;
	int ret;

	ret = hl7139_set_charge_enable(chip, false);
	if (ret) {
		dev_err(dev, "failed to disable charge pump for suspend: %d\n", ret);
		return ret;
	}

	ret = regmap_read(chip->regmap, HL7139_REG_CTRL0, &ctrl0);
	if (ret) {
		dev_err(dev, "failed to verify charge pump shutdown: %d\n", ret);
		return ret;
	}
	if (ctrl0 & HL7139_CTRL0_CHG_EN) {
		dev_err(dev, "charge pump remained enabled; aborting suspend\n");
		return -EBUSY;
	}

	return 0;
}

static int hl7139_resume(struct device *dev)
{
	/* Pumps stay off; the charge-policy service re-enables them. */
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(hl7139_pm_ops, hl7139_suspend, hl7139_resume);

static const struct of_device_id hl7139_of_match[] = {
	{ .compatible = "ayaneo,pocket-evo-hl7139", .data = &hl7139_pocket_evo_data },
	{ .compatible = "halomicro,hl7139" },
	{ }
};
MODULE_DEVICE_TABLE(of, hl7139_of_match);

static const struct i2c_device_id hl7139_i2c_id[] = {
	{ "hl7139-evo", (kernel_ulong_t)&hl7139_pocket_evo_data },
	{ }
};

static const struct hl7139_init_data *hl7139_i2c_init_data(struct i2c_client *client)
{
	const struct i2c_device_id *id;

	for (id = hl7139_i2c_id; id->name[0]; id++)
		if (!strcmp(client->name, id->name))
			return (const struct hl7139_init_data *)id->driver_data;

	return NULL;
}
MODULE_DEVICE_TABLE(i2c, hl7139_i2c_id);

static struct i2c_driver hl7139_driver = {
	.driver = {
		.name = "hl7139-evo",
		.of_match_table = hl7139_of_match,
		.pm = pm_sleep_ptr(&hl7139_pm_ops),
	},
	.probe = hl7139_probe,
	.remove = hl7139_remove,
	.shutdown = hl7139_shutdown,
	.id_table = hl7139_i2c_id,
};
module_i2c_driver(hl7139_driver);

MODULE_DESCRIPTION("Halo Microelectronics HL7139 charge pump driver");
MODULE_LICENSE("GPL");
