# Synthetic Plunk webhook fixtures

Every file here was **written for this plugin's tests**. None was captured
from a Plunk account, and every address, id and timestamp is made up
(`example.com`, `wf_test_*`, `exec_test_*`).

Each file is exactly the shape of Plunk's *default* workflow-webhook body
(the body Plunk sends when the webhook step's Body field is left blank):
`contact`, `workflow`, `execution` and `event`, with the `event` object
holding the trigger event's data as documented by Plunk. Fields the plugin
ignores (`subject`, `from`, `fromName`, `templateId`, `campaignId`,
`contact.data`) are included on purpose so the tests prove they are dropped.

The files double as the payloads for the staging curl procedure in the
README; send them only to a staging forum or a designated test account.
