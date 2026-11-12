# pso_skey (dm/gfx/nvn/nvn_pso_skey.h) as the host writes it into a prewarm row: its size, where its pso_key starts, and the row lengths pso_skey_parse / pso_mesh_skey_parse read.
# The one place the tools that read those rows take them from (pso_offline.py, dm/tools/pso_seed.py), so a change of the header is made here once. Kept out of dmsh_abi.py, which is part
# of the translation chain (dmsh_chain.py FILES): a change there gives every game a new chain version and rebuilds its shader libraries, and these values decide no shader.
SKEY = 512   # sizeof(pso_skey)
KEY = 88     # where its pso_key starts (after vs[24], fs[24], four flags, pso_fz_desc and padding)
# A row from before border (0.5's lists), or also before attr_hi, or also before atest / logic, is shorter, and read with those fields zero
LENGTHS = (2 * SKEY, 2 * SKEY - 2 * 8, 2 * SKEY - 2 * 8 - 2 * 64, 2 * SKEY - 2 * 8 - 2 * 64 - 2 * 8)
