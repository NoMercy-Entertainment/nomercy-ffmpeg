# tools/wav2vec2-gguf/Dockerfile
#
# Dockerised converter for facebook/wav2vec2-xlsr-53-espeak-cv-ft (Apache-2.0)
# into the f16 GGUF the lyricsalign filter loads. The checkpoint (1.26 GB) is
# downloaded at image build, the way tools/spleeter-gguf does it, so a
# conversion is one `docker run` with no host-side Python.
#
#   docker build -t wav2vec2-gguf tools/wav2vec2-gguf
#   docker run --rm -v /path/to/out:/out wav2vec2-gguf /work/checkpoint /out/wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf
#
# A checkpoint already on disk can be mounted over /work/checkpoint instead.
FROM python:3.12-slim

WORKDIR /work
COPY requirements.txt /work/requirements.txt
RUN pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu -r /work/requirements.txt

ADD https://huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft/resolve/main/config.json /work/checkpoint/config.json
ADD https://huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft/resolve/main/vocab.json /work/checkpoint/vocab.json
ADD https://huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft/resolve/main/pytorch_model.bin /work/checkpoint/pytorch_model.bin

COPY convert.py /work/convert.py

ENTRYPOINT ["python", "-I", "/work/convert.py"]
