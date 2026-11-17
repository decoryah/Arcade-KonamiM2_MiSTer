// SPDX-License-Identifier: GPL-2.0
/*
 * m2_mem_wc: write-combined mappings of fixed windows of the FPGA's DDR3, for the Konami M2 core's MPEG daemon
 * (hps/m2mpegd in the core's repository). /dev/mem maps memory outside Linux's RAM as Device memory, which ARM
 * writes a word at a time; Normal Non-cacheable (write-combined) lets the A9 merge the stores.
 *
 * After NDS4MiSTer's nds_mem_wc (https://github.com/SplashDev88/NDS4MiSTer, kernel/nds_mem_wc, GPL-2.0), which
 * credits DreamSTer for the idea; the same structure, with this core's windows. Its rule, kept here: never map the same
 * physical pages as Device memory (/dev/mem) and as Normal memory at once. The daemon maps game RAM only through this
 * device when it is there, and nothing else on the ARM maps game RAM while the core runs.
 *
 * The windows:
 * - game RAM, 0x31000000-0x31FFFFFF (the M2's 0x40000000-0x40FFFFFF): the daemon writes the decoded pictures there;
 * - the board test block, 0x3C000000-0x3C0FFFFF (for measuring the mapping's speed; no core or framework part uses it).
 * A mapping must lie inside one window.
 *
 * M2_MEM_WC_SYNC (ioctl): wmb(), which on this kernel (CONFIG_ARM_HEAVY_MB, CONFIG_OUTER_CACHE_SYNC) is a dsb and the
 * L2 controller's cache sync. The PL310's store buffer doesn't drain by itself (erratum 769419, set in the MiSTer
 * kernel's config), and a user-space dsb doesn't drain it: the daemon calls this after a picture's stores and before it
 * writes the done word, so the FPGA reads the whole picture.
 */

#include <linux/fs.h>
#include <linux/io.h>
#include <linux/ioctl.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/version.h>
#include <asm/barrier.h>

#define M2_MEM_WC_NAME "m2_mem_wc"
#define M2_MEM_WC_SYNC _IO('M', 0x32)

static const struct {
	phys_addr_t base;
	phys_addr_t size;
} m2_wc_windows[] = {
	{ 0x31000000, 0x01000000 },	/* game RAM */
	{ 0x3c000000, 0x00100000 },	/* the board test block */
};

static int m2_mem_wc_mmap(struct file *file, struct vm_area_struct *vma)
{
	const size_t size = vma->vm_end - vma->vm_start;
	const phys_addr_t offset = (phys_addr_t)vma->vm_pgoff << PAGE_SHIFT;
	bool inside = false;
	size_t i;

	if (!size || offset + size < offset)
		return -EPERM;
	for (i = 0; i < ARRAY_SIZE(m2_wc_windows); i++)
		if (offset >= m2_wc_windows[i].base && offset + size <= m2_wc_windows[i].base + m2_wc_windows[i].size)
			inside = true;
	if (!inside)
		return -EPERM;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
	vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP);
#else
	vma->vm_flags |= VM_IO | VM_DONTEXPAND | VM_DONTDUMP;
#endif
	vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
	if (remap_pfn_range(vma, vma->vm_start, vma->vm_pgoff, size, vma->vm_page_prot))
		return -EAGAIN;
	return 0;
}

static long m2_mem_wc_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	if (cmd != M2_MEM_WC_SYNC)
		return -ENOTTY;
	wmb();
	return 0;
}

static const struct file_operations m2_mem_wc_fops = {
	.owner = THIS_MODULE,
	.mmap = m2_mem_wc_mmap,
	.unlocked_ioctl = m2_mem_wc_ioctl,
	.llseek = noop_llseek,
};

static struct miscdevice m2_mem_wc_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = M2_MEM_WC_NAME,
	.fops = &m2_mem_wc_fops,
	.mode = 0600,
};

static int __init m2_mem_wc_init(void)
{
	int result = misc_register(&m2_mem_wc_device);
	size_t i;

	if (result)
		return result;
	for (i = 0; i < ARRAY_SIZE(m2_wc_windows); i++)
		pr_info("m2_mem_wc: window [0x%llx, 0x%llx)\n", (unsigned long long)m2_wc_windows[i].base,
			(unsigned long long)(m2_wc_windows[i].base + m2_wc_windows[i].size));
	return 0;
}

static void __exit m2_mem_wc_exit(void)
{
	misc_deregister(&m2_mem_wc_device);
}

module_init(m2_mem_wc_init);
module_exit(m2_mem_wc_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Write-combined windows of the FPGA DDR3 for the Konami M2 core's MPEG daemon");
