import argparse
import uuid
import subprocess
import os


YAML_TEMPLATE = os.path.dirname(__file__) + os.sep + 'template_job.yaml'


def replaceInLines(lines, pattern, value):
    newLines = []
    for line in lines:
        if pattern in line:
            newLines.append(line.replace(pattern, value))
        else:
            newLines.append(line)
    return newLines


def create_yaml_job(acrName):
    """Create yaml job."""

    with open(YAML_TEMPLATE, 'r') as fid:
        template_lines = fid.readlines()

    jobUUID = str(uuid.uuid4())
    jobName = 'job-{}'.format(jobUUID)
    job_lines = replaceInLines(template_lines, "<UUID>",  jobUUID)
    job_lines = replaceInLines(job_lines, "<ACR_NAME>", acrName)

    with open(jobName, 'w') as fid:
        fid.writelines(job_lines)

    return jobName


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
    description='Submits a number of jobs to Azure Kubernetes cluster with different UUIDs')

    parser.add_argument('--njobs', type=int,
                        help='The number of jobs to submit')
    
    parser.add_argument('--acrName', type=str,
                        help='Name of the container registry containing Docker job images.')

    args = parser.parse_args()

    for job in range(0, args.njobs):
        subprocess.check_output(["/usr/local/bin/kubectl", "apply", "-f", create_yaml_job(args.acrName)])