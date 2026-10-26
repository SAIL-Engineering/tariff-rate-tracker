// Generated from SAIL server/src/shared/duty/shipmentRules.ts. Do not edit.
// Source SHA256: 2621a3496ce7322f44a905a38781b8893650b290c1edcb233a5ce99ce9d771e1
export function unavailableShipment(reason, bundle) {
    return { contract_version: 'sail.shipment-result/v1', dataset_version: bundle?.dataset_version ?? null,
        revision: bundle?.revision ?? null, evidence_snapshot_id: bundle?.evidence_snapshot_id ?? null,
        status: 'unresolved_source', components: [], rule_decisions: [], coverage_decisions: [], applied_rules: [], suppressed_rules: [],
        missing_inputs: [], required_facts: {}, claim_options: [], source_errors: [reason], known_subtotal: 0, complete_total: null };
}
function timestamp(value) {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$/.test(value))
        return NaN;
    const day = new Date(`${value.slice(0, 10)}T00:00:00Z`);
    if (!Number.isFinite(day.getTime()) || day.toISOString().slice(0, 10) !== value.slice(0, 10)
        || Number(value.slice(11, 13)) > 23 || Number(value.slice(14, 16)) > 59 || Number(value.slice(17, 19)) > 59)
        return NaN;
    return Date.parse(value);
}
function validScope(s) {
    if (s == null)
        return true;
    const array = (x, pattern) => x == null || Array.isArray(x) && x.every(v => typeof v === 'string' && pattern.test(v));
    return typeof s === 'object' && !Array.isArray(s)
        && Object.keys(s).every(k => ['hts_exact', 'hts_prefixes', 'countries', 'from', 'until'].includes(k))
        && array(s.hts_exact, /^\d{10}$/) && array(s.hts_prefixes, /^(?:\d{2}){1,5}$/)
        && array(s.countries, /^.+$/) && (s.from == null || Number.isFinite(timestamp(s.from)))
        && (s.until == null || Number.isFinite(timestamp(s.until)))
        && (s.from == null || s.until == null || timestamp(s.from) < timestamp(s.until));
}
function matches(scope, hts, country, at) {
    if (!scope)
        return true;
    const product = scope.hts_exact == null && scope.hts_prefixes == null
        || scope.hts_exact?.includes(hts) || scope.hts_prefixes?.some(p => hts.startsWith(p));
    return Boolean(product && (scope.countries == null || scope.countries.includes(country))
        && (scope.from == null || at >= timestamp(scope.from))
        && (scope.until == null || at < timestamp(scope.until)));
}
function canonical(value) {
    if (Array.isArray(value))
        return `[${value.map(canonical).join(',')}]`;
    if (value && typeof value === 'object')
        return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b))
            .map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(',')}}`;
    return JSON.stringify(value);
}
const unique = (items) => [...new Set(items)].sort();
const val = (value = null, missing = [], errors = []) => ({ value, missing, errors });
function evaluateBundle(bundle, hts10, country, entryAt, facts = {}) {
    const fail = (reason) => unavailableShipment(reason, bundle);
    const at = timestamp(entryAt);
    if (!/^\d{10}$/.test(hts10) || typeof country !== 'string' || !Number.isFinite(at))
        return fail('invalid_shipment_identity_or_entry_timestamp');
    if (!bundle || bundle.contract_version !== 'sail.shipment-rules/v1' || !bundle.dataset_version
        || !bundle.evidence_snapshot_id || !bundle.coverage_requirements?.length
        || !Array.isArray(bundle.rules) || !Array.isArray(bundle.sources) || !Array.isArray(bundle.products) || !Array.isArray(bundle.countries))
        return fail('unsupported_or_incomplete_contract');
    if (!bundle.products.includes(hts10))
        return fail('product_not_valid_in_revision');
    if (!bundle.countries.includes(country))
        return fail('origin_not_covered');
    if (!Number.isFinite(timestamp(bundle.valid_from)) || !Number.isFinite(timestamp(bundle.valid_until))
        || at < timestamp(bundle.valid_from) || at >= timestamp(bundle.valid_until))
        return fail('entry_outside_bundle_interval');
    const rules = new Map();
    for (const rule of bundle.rules) {
        if (!rule.id || typeof rule.id !== 'string')
            return fail('missing_rule_id');
        if (rules.has(rule.id) && canonical(rules.get(rule.id)) !== canonical(rule))
            return fail(`conflicting_rule:${rule.id}`);
        rules.set(rule.id, rule);
    }
    if ([...bundle.rules, ...(bundle.coverage ?? [])].some(r => !validScope(r.scope)))
        return fail('invalid_scope');
    const sources = new Map();
    for (const source of bundle.sources) {
        if (!source.id || typeof source.id !== 'string')
            return fail('missing_source_id');
        if (sources.has(source.id) && canonical(sources.get(source.id)) !== canonical(source))
            return fail(`conflicting_source:${source.id}`);
        sources.set(source.id, source);
    }
    const validSource = (id) => {
        const s = sources.get(id);
        return Boolean(s && s.status === 'verified' && /^[a-f0-9]{64}$/.test(s.sha256) && s.url && s.citation);
    };
    if (facts == null || typeof facts !== 'object' || Array.isArray(facts))
        return fail('invalid_shipment_facts');
    if (facts.claims != null && (!Array.isArray(facts.claims) || facts.claims.some(c => typeof c !== 'string')))
        return fail('invalid_shipment_claims');
    for (const claim of facts.claims ?? []) {
        const definitions = (bundle.claim_definitions ?? []).filter(c => c.id === claim);
        if (definitions.length !== 1 || !definitions[0].source_ids.length || !definitions[0].source_ids.every(validSource)
            || !definitions[0].rule_ids.length || !definitions[0].rule_ids.every(id => rules.has(id)))
            return fail(`claim_not_priced:${claim}`);
    }
    const result = { ...fail(''), status: 'complete', source_errors: [], complete_total: 0 };
    result.claim_options = (bundle.claim_definitions ?? []).flatMap(claim => {
        const candidates = claim.candidate_rule_ids ?? [];
        if (!candidates.length || !candidates.every(id => rules.has(id))
            || !claim.source_ids.length || !claim.source_ids.every(validSource))
            return [];
        const matched = candidates.filter(id => matches(rules.get(id).scope, hts10, country, at));
        return matched.length ? [{ id: claim.id, label: claim.label, candidate_rule_ids: matched,
                citations: claim.source_ids.map(id => sources.get(id)) }] : [];
    });
    for (const authority of bundle.coverage_requirements) {
        const coverage = (bundle.coverage ?? []).filter(c => c.authority === authority && matches(c.scope, hts10, country, at));
        const applicable = [...rules.values()].filter(r => r.authority === authority && matches(r.scope, hts10, country, at));
        const unverified = !coverage.length || coverage.some(c => c.status !== 'verified' || !c.source_ids?.length || !c.source_ids.every(validSource)
            || !Array.isArray(c.rule_ids) || !c.rule_ids.every(id => rules.get(id)?.authority === authority)
            || (c.determination === 'rules' ? !c.rule_ids.length
                : c.determination !== 'no_applicable_rules' || c.rule_ids.length > 0 || applicable.length > 0))
            || applicable.some(r => !coverage.some(c => c.rule_ids?.includes(r.id)));
        if (unverified)
            result.source_errors.push(`coverage_unverified:${authority}`);
        result.coverage_decisions.push({ authority, status: unverified ? 'unresolved_source' : 'verified',
            matched_rule_ids: applicable.map(r => r.id).sort(), attestations: coverage.map(c => ({ ...c,
                citations: (c.source_ids ?? []).map(id => sources.get(id)).filter((v) => Boolean(v)),
            })) });
    }
    const cache = new Map();
    const visiting = new Set();
    function expr(x) {
        if (!x || typeof x !== 'object')
            return val(null, [], ['invalid_expression']);
        const keys = ['value', 'fact', 'claim', 'rule_amount', 'rule_applies', 'authority_covered', 'unresolved_source', 'op'].filter(k => k in x);
        if (keys.length !== 1)
            return val(null, [], ['invalid_expression']);
        if ('authority_covered' in x) {
            if (typeof x.authority_covered !== 'string' || !x.authority_covered.length)
                return val(null, [], ['invalid_coverage_dependency']);
            const decisions = result.coverage_decisions.filter(d => d.authority === x.authority_covered);
            return decisions.length === 1 && decisions[0].status === 'verified' ? val(true)
                : val(null, [], [`coverage_dependency_unverified:${x.authority_covered}`]);
        }
        if ('unresolved_source' in x)
            return typeof x.unresolved_source === 'string' && x.unresolved_source.length
                ? val(null, [], [`source_discrepancy:${x.unresolved_source}`]) : val(null, [], ['invalid_source_discrepancy']);
        if ('value' in x)
            return ['number', 'boolean', 'string'].includes(typeof x.value)
                && (typeof x.value !== 'number' || Number.isFinite(x.value)) ? val(x.value) : val(null, [], ['invalid_literal']);
        if ('claim' in x) {
            if (facts.claims != null && (!Array.isArray(facts.claims) || facts.claims.some(v => typeof v !== 'string')))
                return val(null, ['claims']);
            return val(facts.claims?.includes(x.claim) ?? false);
        }
        if ('fact' in x) {
            const d = bundle.fact_definitions?.[x.fact], value = facts[x.fact];
            if (!d)
                return val(null, [], [`unknown_fact:${x.fact}`]);
            const okay = typeof value === d.type && (d.type !== 'number' || Number.isFinite(value))
                && (d.minimum == null || typeof value === 'number' && value >= d.minimum)
                && (d.maximum == null || typeof value === 'number' && value <= d.maximum)
                && (d.enum == null || d.enum.includes(value));
            return okay ? val(value) : val(null, [x.fact]);
        }
        if ('rule_applies' in x) {
            const r = resolve(x.rule_applies, true);
            return val(r.state === 'unresolved' ? null : r.state === 'applied', r.missing, r.errors);
        }
        if ('rule_amount' in x) {
            const r = resolve(x.rule_amount);
            return val(r.amount, r.missing, r.errors);
        }
        const { op, args } = x;
        if (op === 'if') {
            if (args?.length !== 3)
                return val(null, [], ['invalid_arity:if']);
            const condition = expr(args[0]);
            if (condition.value == null)
                return condition;
            if (typeof condition.value !== 'boolean')
                return val(null, [], ['non_boolean_condition']);
            return expr(args[condition.value ? 1 : 2]);
        }
        const arities = { subtract: 2, divide: 2, eq: 2, lt: 2, lte: 2, gt: 2, gte: 2, not: 1 };
        if (!(op in arities) && !['add', 'multiply', 'min', 'max', 'and', 'or'].includes(op)
            || !args?.length || op in arities && arities[op] !== args.length)
            return val(null, [], [`invalid_operator_or_arity:${op}`]);
        const xs = args.map(expr);
        if (op === 'and' || op === 'or') {
            const decisive = op === 'or';
            if (xs.some(v => v.value === decisive))
                return val(decisive);
        }
        const missing = unique(xs.flatMap(v => v.missing)), errors = unique(xs.flatMap(v => v.errors));
        if (missing.length || errors.length)
            return val(null, missing, errors);
        const values = xs.map(v => v.value);
        if (['and', 'or', 'not'].includes(op)) {
            if (values.some(v => typeof v !== 'boolean'))
                return val(null, [], ['non_boolean_operand']);
        }
        else if (op !== 'eq' && values.some(v => typeof v !== 'number'))
            return val(null, [], ['non_numeric_operand']);
        const nums = values;
        let answer;
        switch (op) {
            case 'add':
                answer = nums.reduce((a, b) => a + b);
                break;
            case 'subtract':
                answer = nums[0] - nums[1];
                break;
            case 'multiply':
                answer = nums.reduce((a, b) => a * b);
                break;
            case 'divide':
                answer = nums[0] / nums[1];
                break;
            case 'min':
                answer = Math.min(...nums);
                break;
            case 'max':
                answer = Math.max(...nums);
                break;
            case 'eq':
                answer = values[0] === values[1];
                break;
            case 'lt':
                answer = nums[0] < nums[1];
                break;
            case 'lte':
                answer = nums[0] <= nums[1];
                break;
            case 'gt':
                answer = nums[0] > nums[1];
                break;
            case 'gte':
                answer = nums[0] >= nums[1];
                break;
            case 'and':
                answer = values.every(Boolean);
                break;
            case 'or':
                answer = values.some(Boolean);
                break;
            case 'not':
                answer = !values[0];
                break;
            default: return val(null, [], [`invalid_operator_or_arity:${op}`]);
        }
        return typeof answer === 'number' && !Number.isFinite(answer) ? val(null, [], ['non_finite_result']) : val(answer);
    }
    function resolve(id, applicabilityOnly = false) {
        const cacheKey = `${applicabilityOnly ? 'applies' : 'amount'}:${id}`;
        const old = cache.get(cacheKey);
        if (old)
            return old;
        const r = rules.get(id);
        const blank = { amount: null, missing: [], errors: [], state: 'unresolved' };
        if (!r)
            return { ...blank, errors: [`unknown_rule:${id}`] };
        if (visiting.has(cacheKey))
            return { ...blank, errors: [`dependency_cycle:${id}`] };
        visiting.add(cacheKey);
        const finish = (value) => { visiting.delete(cacheKey); cache.set(cacheKey, value); return value; };
        if (!matches(r.scope, hts10, country, at))
            return finish({ ...blank, amount: 0, state: 'not_applicable' });
        // A claim must have reviewed effects (including unchanged treatment) for
        // every potentially applicable action. Test before predicates: a claim may
        // revive an action suppressed on the unclaimed path.
        const unpriced = (facts.claims ?? []).filter(claim => !bundle.claim_definitions?.find(c => c.id === claim)?.rule_ids.includes(id));
        if (unpriced.length)
            return finish({ ...blank, errors: unpriced.map(claim => `claim_not_priced:${claim}:${id}`) });
        if (r.verification !== 'verified' || !r.source_ids?.length || !r.source_ids.every(validSource) || !r.action_id || !r.authority)
            return finish({ ...blank, errors: [`rule_source_unverified:${id}`] });
        const condition = r.when ? expr(r.when) : val(true);
        if (condition.value === false)
            return finish({ ...blank, amount: 0, state: 'not_applicable' });
        const suppress = r.suppressed_when ? expr(r.suppressed_when) : val(false);
        if (suppress.value === true)
            return finish({ ...blank, amount: 0, state: 'suppressed' });
        if (condition.value !== true || suppress.value !== false)
            return finish({ ...blank,
                missing: unique([...condition.missing, ...suppress.missing]),
                errors: unique([...condition.errors, ...suppress.errors,
                    ...(condition.value != null && typeof condition.value !== 'boolean' ? ['non_boolean_condition'] : []),
                    ...(suppress.value != null && typeof suppress.value !== 'boolean' ? ['non_boolean_condition'] : [])]),
            });
        // A zero entered value or missing valuation cannot revive an excluded action.
        if (applicabilityOnly)
            return finish({ ...blank, amount: 0, state: 'applied' });
        for (const constraint of r.input_constraints ?? []) {
            const tested = expr(constraint.test);
            // A proven contradiction needs correction hints. Missing operands and
            // unresolved legal sources must not mark already supplied facts missing.
            if (tested.value !== true)
                return finish({ ...blank,
                    missing: unique([...tested.missing, ...(tested.value === false ? constraint.inputs : [])]),
                    errors: unique([...tested.errors,
                        ...(tested.value != null && typeof tested.value !== 'boolean' ? ['non_boolean_constraint'] : [])]) });
        }
        const amount = expr(r.formula);
        if (amount.value != null && (typeof amount.value !== 'number' || amount.value < 0))
            amount.errors.push('invalid_duty_amount');
        return finish({ amount: typeof amount.value === 'number' && !amount.errors.length ? amount.value : null,
            missing: amount.missing, errors: amount.errors,
            state: typeof amount.value === 'number' && !amount.errors.length ? 'applied' : 'unresolved' });
    }
    for (const id of [...rules.keys()].sort()) {
        const r = rules.get(id), resolved = resolve(id);
        if (matches(r.scope, hts10, country, at))
            result.rule_decisions.push({
                rule_id: id, action_id: r.action_id, authority: r.authority, outcome: resolved.state,
                scope: r.scope, when: r.when, suppressed_when: r.suppressed_when,
                reporting_codes: r.reporting_codes, source_ids: r.source_ids,
                citations: r.source_ids.map(s => sources.get(s)).filter((s) => Boolean(s)),
                missing_inputs: resolved.missing, source_errors: resolved.errors,
            });
        if (resolved.state === 'not_applicable')
            continue;
        result.components.push({ rule_id: id, action_id: r.action_id, authority: r.authority, kind: r.kind,
            amount: resolved.amount, status: resolved.state, formula: r.formula, reporting_codes: r.reporting_codes,
            citations: r.source_ids.map(s => sources.get(s)).filter((s) => Boolean(s)),
            missing_inputs: resolved.missing, source_errors: resolved.errors });
        result.missing_inputs.push(...resolved.missing);
        result.source_errors.push(...resolved.errors);
        if (resolved.state === 'applied')
            result.applied_rules.push(id);
        if (resolved.state === 'suppressed')
            result.suppressed_rules.push(id);
        if (resolved.amount != null)
            result.known_subtotal += resolved.amount;
    }
    result.missing_inputs = unique(result.missing_inputs);
    result.required_facts = Object.fromEntries(result.missing_inputs
        .filter(key => bundle.fact_definitions[key]).map(key => [key, bundle.fact_definitions[key]]));
    result.source_errors = unique(result.source_errors);
    result.status = result.source_errors.length ? 'unresolved_source' : result.missing_inputs.length ? 'needs_inputs' : 'complete';
    result.complete_total = result.status === 'complete' ? result.known_subtotal : null;
    return result;
}
/** Treat malformed/untrusted persisted bundles as unavailable, never as zero duty. */
export function evaluateShipmentBundle(bundle, hts10, country, entryAt, facts = {}) {
    try {
        return evaluateBundle(bundle, hts10, country, entryAt, facts);
    }
    catch {
        return unavailableShipment('invalid_shipment_rule_bundle', bundle);
    }
}
// Bundle indexes and serving preflight use the same strict instants as evaluation.
export { timestamp as shipmentTimestamp };
