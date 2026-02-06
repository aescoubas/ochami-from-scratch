import yaml
import sys

def reorder_yaml(input_file, output_file):
    with open(input_file, 'r') as f:
        docs = list(yaml.safe_load_all(f))

    # Identify docs by kind and name
    def get_info(doc):
        if not doc: return 'None', 'None'
        return doc.get('kind'), doc.get('metadata', {}).get('name')

    pods = []
    others = []

    for doc in docs:
        kind, name = get_info(doc)
        if kind == 'Pod':
            pods.append(doc)
        else:
            others.append(doc)

    # Sort pods: localhost (postgres) first, then ochami-smd, then others
    def pod_sorter(doc):
        _, name = get_info(doc)
        if name == 'localhost': # This is postgres due to sed
            return 0
        if name == 'ochami-smd':
            return 1
        if name == 'ochami-bss':
            return 2 # BSS waits for SMD
        if name == 'ochami-cloud-init':
            return 3 # cloud-init waits for SMD
        return 4

    pods.sort(key=pod_sorter)

    # Write back
    with open(output_file, 'w') as f:
        yaml.dump_all(others + pods, f, default_flow_style=False)

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python3 quadlet_reorder.py <input_file> <output_file>")
        sys.exit(1)
    reorder_yaml(sys.argv[1], sys.argv[2])