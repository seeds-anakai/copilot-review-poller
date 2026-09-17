import json
import os
import subprocess


COPILOT_REVIEWER = 'copilot-pull-request-reviewer[bot]'
COPILOT_REQUESTED_REVIEWER_LOGINS = {'Copilot', COPILOT_REVIEWER}
DEPENDABOT_USER = 'dependabot[bot]'
TARGET_REPOSITORY = os.environ['TARGET_REPOSITORY']


def gh_api(*args: str):
    result = subprocess.run(
        ['gh', 'api', *args],
        capture_output=True,
        check=False,
        text=True,
    )

    if result.returncode != 0:
        message = result.stderr.strip() or 'GitHub API request failed'
        raise RuntimeError(message)

    if not result.stdout.strip():
        return None

    return json.loads(result.stdout)


def flatten_pages(pages: list[list[dict]]) -> list[dict]:
    return [item for page in pages for item in page]


def get_open_pull_requests() -> list[dict]:
    pages = gh_api(
        '--paginate',
        '--slurp',
        f'repos/{TARGET_REPOSITORY}/pulls?state=open&per_page=100',
    )
    return flatten_pages(pages)


def get_requested_reviewers(number: int) -> list[dict]:
    response = gh_api(
        f'repos/{TARGET_REPOSITORY}/pulls/{number}/requested_reviewers',
    )
    return response.get('users', [])


def get_reviews(number: int) -> list[dict]:
    pages = gh_api(
        '--paginate',
        '--slurp',
        f'repos/{TARGET_REPOSITORY}/pulls/{number}/reviews?per_page=100',
    )
    return flatten_pages(pages)


def has_current_copilot_review(reviews: list[dict], head_sha: str) -> bool:
    return any(
        review.get('user', {}).get('login') == COPILOT_REVIEWER
        and review.get('commit_id') == head_sha
        and review.get('submitted_at')
        and review.get('state') not in {'DISMISSED', 'PENDING'}
        for review in reviews
    )


def request_copilot_review(number: int) -> None:
    gh_api(
        '--method',
        'POST',
        f'repos/{TARGET_REPOSITORY}/pulls/{number}/requested_reviewers',
        '-f',
        f'reviewers[]={COPILOT_REVIEWER}',
    )


def process_pull_request(pull_request: dict) -> str:
    number = pull_request['number']

    if pull_request.get('draft'):
        return 'draft'

    if pull_request.get('user', {}).get('login') == DEPENDABOT_USER:
        return 'dependabot'

    head_sha = pull_request['head']['sha']
    requested_reviewers = get_requested_reviewers(number)
    if any(
        reviewer.get('login') in COPILOT_REQUESTED_REVIEWER_LOGINS
        for reviewer in requested_reviewers
    ):
        return 'requested'

    if has_current_copilot_review(get_reviews(number), head_sha):
        return 'reviewed'

    latest = gh_api(f'repos/{TARGET_REPOSITORY}/pulls/{number}')
    if (
        latest.get('state') != 'open'
        or latest.get('draft')
        or latest.get('head', {}).get('sha') != head_sha
    ):
        return 'changed'

    request_copilot_review(number)
    print(json.dumps({'pull_request': number, 'action': 'requested'}))
    return 'requested_now'


def handler(event, context):
    pull_requests = get_open_pull_requests()
    counts = {
        'scanned': len(pull_requests),
        'draft': 0,
        'dependabot': 0,
        'requested': 0,
        'reviewed': 0,
        'changed': 0,
        'requested_now': 0,
        'errors': 0,
    }
    errors = []

    for pull_request in pull_requests:
        number = pull_request.get('number')
        try:
            result = process_pull_request(pull_request)
            counts[result] += 1
        except Exception as error:
            counts['errors'] += 1
            errors.append({'pull_request': number, 'error': str(error)})
            print(json.dumps(errors[-1]))

    summary = {'repository': TARGET_REPOSITORY, **counts}
    print(json.dumps(summary))

    if errors:
        raise RuntimeError(f'{len(errors)} pull request(s) failed')

    return summary
