import { createClient } from '@supabase/supabase-js';
import type { NextApiRequest, NextApiResponse } from 'next';

import { withProjectAccess } from '@/lib/middleware/common';
import { getQueryStats } from '@/lib/supabase';
import { safeParseInt } from '@/lib/utils.edge';
import { Database } from '@/types/supabase';
import { Project, PromptQueryStat } from '@/types/types';

type Data =
  | {
      status?: string;
      error?: string;
    }
  | { queries: PromptQueryStat[] };

const allowedMethods = ['GET'];

// Admin access to Supabase, bypassing RLS.
const supabaseAdmin = createClient<Database>(
  process.env.NEXT_PUBLIC_SUPABASE_URL || '',
  process.env.SUPABASE_SERVICE_ROLE_KEY || '',
);

export default withProjectAccess(
  allowedMethods,
  async (req: NextApiRequest, res: NextApiResponse<Data>) => {
    const projectId = req.query.id as Project['id'];

    if (req.method === 'GET') {
      const limit = Math.min(safeParseInt(req.query.limit as string, 50), 50);
      const page = safeParseInt(req.query.page as string, 0);
      const { data: queries, error } = await getQueryStats(
        supabaseAdmin,
        projectId,
        req.query.from as string,
        req.query.to as string,
        limit,
        page,
      );

      if (error) {
        return res.status(400).json({ error: error.message });
      }

      if (!queries) {
        return res.status(404).json({ error: 'No results found.' });
      }

      return res.status(200).json({ queries });
    }

    return res.status(400).end();
  },
);
