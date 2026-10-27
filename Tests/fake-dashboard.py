#!/usr/bin/python3
"""No network or credentials. Controlled fixtures for dashboard account isolation."""
import json, os, sys, time
mode = os.environ.get('ORBIT_DASHBOARD_TEST_MODE', 'normal')
account_reads = 0
for line in sys.stdin:
    value = json.loads(line)
    method, ident = value.get('method'), value.get('id')
    if ident is None:
        continue
    if method == 'initialize':
        result = {'userAgent': 'dashboard-fixture'}
    elif method == 'account/read':
        account_reads += 1
        result = {'account': {'type': 'chatgpt', 'id': 'account-b' if mode == 'switch' and account_reads > 1 else 'account-a', 'email': None, 'planType': 'plus'}}
    elif method == 'account/usage/read':
        if mode == 'slow': time.sleep(0.2)
        if mode == 'missing':
            print(json.dumps({'id':ident,'error':{'code':-32601,'message':'unsupported'}}),flush=True)
            continue
        result = {'summary': {'lifetimeTokens': 1000, 'peakDailyTokens': 500, 'currentStreakDays': 2}, 'dailyUsageBuckets': [{'startDate':'2026-10-26','tokens':500}]}
    elif method == 'thread/list':
        result = {'data':[{'id':'__orbit_dashboard_fixture__','name':'Fixture session','cwd':'/tmp/fixture','updatedAt':1793000000,'model':'fixture'}]}
    else:
        print(json.dumps({'id':ident,'error':{'code':-32601,'message':'unsupported'}}),flush=True)
        continue
    print(json.dumps({'id':ident,'result':result}),flush=True)
