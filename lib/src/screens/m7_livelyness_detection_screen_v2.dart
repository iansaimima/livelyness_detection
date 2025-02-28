import 'dart:async';
import 'package:livelyness_detection/index.dart';

class LivelynessDetectionPageV2 extends StatelessWidget {
  final DetectionConfig config;

  const LivelynessDetectionPageV2({
    required this.config,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LivelynessDetectionScreenV2(
          config: config,
        ),
      ),
    );
  }
}

class LivelynessDetectionScreenV2 extends StatefulWidget {
  final DetectionConfig config;

  const LivelynessDetectionScreenV2({
    required this.config,
    super.key,
  });

  @override
  State<LivelynessDetectionScreenV2> createState() => _LivelynessDetectionScreenAndroidState();
}

class _LivelynessDetectionScreenAndroidState extends State<LivelynessDetectionScreenV2> {
  //* MARK: - Private Variables
  //? =========================================================
  final _faceDetectionController = BehaviorSubject<FaceDetectionModel>();

  final options = FaceDetectorOptions(
    enableContours: true,
    enableClassification: true,
    enableTracking: true,
    enableLandmarks: true,
    performanceMode: FaceDetectorMode.accurate,
    minFaceSize: 0.05,
  );
  late final faceDetector = FaceDetector(options: options);
  bool _didCloseEyes = false;
  bool _isProcessingStep = false;

  late final List<LivelynessStepItem> _steps;
  final GlobalKey<LivelynessDetectionStepOverlayState> _stepsKey = GlobalKey<LivelynessDetectionStepOverlayState>();

  CameraState? _cameraState;
  bool _isProcessing = false;
  late bool _isInfoStepCompleted;
  Timer? _timerToDetectFace;
  bool _isCaptureButtonVisible = false;
  bool _isCompleted = false;

  //* MARK: - Life Cycle Methods
  //? =========================================================
  @override
  void initState() {
    _preInitCallBack();
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _postFrameCallBack(),
    );
  }

  @override
  void deactivate() {
    faceDetector.close();
    super.deactivate();
  }

  @override
  void dispose() {
    _faceDetectionController.close();
    _timerToDetectFace?.cancel();
    _timerToDetectFace = null;
    super.dispose();
  }

  //* MARK: - Private Methods for Business Logic
  //? =========================================================
  void _preInitCallBack() {
    _steps = widget.config.steps;
    _isInfoStepCompleted = !widget.config.startWithInfoScreen;
  }

  void _postFrameCallBack() {
    if (_isInfoStepCompleted) {
      _startTimer();
    }
  }

  Future<void> _processCameraImage(AnalysisImage img) async {
    if (_isProcessing) {
      return;
    }
    if (mounted) {
      setState(
        () => _isProcessing = true,
      );
    }
    final inputImage = img.toInputImage();

    try {
      final List<Face> detectedFaces = await faceDetector.processImage(inputImage);
      _faceDetectionController.add(
        FaceDetectionModel(
          faces: detectedFaces,
          absoluteImageSize: inputImage.metadata!.size,
          rotation: 0,
          imageRotation: img.inputImageRotation,
          croppedSize: img.croppedSize,
        ),
      );
      await _processImage(inputImage, detectedFaces);
      if (mounted) {
        setState(
          () => _isProcessing = false,
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _isProcessing = false,
        );
      }
      debugPrint("...sending image resulted error $error");
    }
  }

  Future<void> _processImage(InputImage img, List<Face> faces) async {
    try {
      if (faces.isEmpty) {
        _resetSteps();
        return;
      }
      final Face firstFace = faces.first;
      final landmarks = firstFace.landmarks;
      // Get landmark positions for relevant facial features
      final Point<int>? leftEye = landmarks[FaceLandmarkType.leftEye]?.position;
      final Point<int>? rightEye = landmarks[FaceLandmarkType.rightEye]?.position;
      final Point<int>? leftCheek = landmarks[FaceLandmarkType.leftCheek]?.position;
      final Point<int>? rightCheek = landmarks[FaceLandmarkType.rightCheek]?.position;
      final Point<int>? leftEar = landmarks[FaceLandmarkType.leftEar]?.position;
      final Point<int>? rightEar = landmarks[FaceLandmarkType.rightEar]?.position;
      final Point<int>? leftMouth = landmarks[FaceLandmarkType.leftMouth]?.position;
      final Point<int>? rightMouth = landmarks[FaceLandmarkType.rightMouth]?.position;

      // Calculate symmetry values based on corresponding landmark positions
      final Map<String, double> symmetry = {};
      final eyeSymmetry = calculateSymmetry(
        leftEye,
        rightEye,
      );
      symmetry['eyeSymmetry'] = eyeSymmetry;

      final cheekSymmetry = calculateSymmetry(
        leftCheek,
        rightCheek,
      );
      symmetry['cheekSymmetry'] = cheekSymmetry;

      final earSymmetry = calculateSymmetry(
        leftEar,
        rightEar,
      );
      symmetry['earSymmetry'] = earSymmetry;

      final mouthSymmetry = calculateSymmetry(
        leftMouth,
        rightMouth,
      );
      symmetry['mouthSymmetry'] = mouthSymmetry;
      double total = 0.0;
      symmetry.forEach((key, value) {
        total += value;
      });
      final double average = total / symmetry.length;
      if (kDebugMode) {
        print("Face Symmetry: $average");
      }
      if (_isProcessingStep && _steps[_stepsKey.currentState?.currentIndex ?? 0].step == LivelynessStep.blink) {
        if (_didCloseEyes) {
          if ((faces.first.leftEyeOpenProbability ?? 1.0) < 0.75 && (faces.first.rightEyeOpenProbability ?? 1.0) < 0.75) {
            await _completeStep(
              step: _steps[_stepsKey.currentState?.currentIndex ?? 0].step,
            );
          }
        }
      }
      _detect(
        face: firstFace,
        step: _steps[_stepsKey.currentState?.currentIndex ?? 0].step,
      );
    } catch (e) {
      _startProcessing();
    }
  }

  Future<void> _completeStep({
    required LivelynessStep step,
  }) async {
    final int indexToUpdate = _steps.indexWhere(
      (p0) => p0.step == step,
    );

    _steps[indexToUpdate] = _steps[indexToUpdate].copyWith(
      isCompleted: true,
    );
    if (mounted) {
      setState(() {});
    }
    await _stepsKey.currentState?.nextPage();
    _stopProcessing();
  }

  void _detect({
    required Face face,
    required LivelynessStep step,
  }) async {
    switch (step) {
      case LivelynessStep.blink:
        const double blinkThreshold = 0.25;
        if ((face.leftEyeOpenProbability ?? 1.0) < (blinkThreshold) && (face.rightEyeOpenProbability ?? 1.0) < (blinkThreshold)) {
          _startProcessing();
          if (mounted) {
            setState(
              () => _didCloseEyes = true,
            );
          }
        }
        break;
      case LivelynessStep.turnLeft:
        const double headTurnThreshold = 45.0;
        if ((face.headEulerAngleY ?? 0) > (headTurnThreshold)) {
          _startProcessing();
          await _completeStep(step: step);
        }
        break;
      case LivelynessStep.turnRight:
        const double headTurnThreshold = -50.0;
        if ((face.headEulerAngleY ?? 0) < (headTurnThreshold)) {
          _startProcessing();
          await _completeStep(step: step);
        }
        break;
      case LivelynessStep.smile:
        const double smileThreshold = 0.75;
        if ((face.smilingProbability ?? 0) > (smileThreshold)) {
          _startProcessing();
          await _completeStep(step: step);
        }
        break;
    }
  }

  void _startProcessing() {
    if (!mounted) {
      return;
    }
    setState(
      () => _isProcessingStep = true,
    );
  }

  void _stopProcessing() {
    if (!mounted) {
      return;
    }
    setState(
      () => _isProcessingStep = false,
    );
  }

  void _startTimer() {
    _timerToDetectFace = Timer(
      Duration(seconds: widget.config.maxSecToDetect),
      () {
        _timerToDetectFace?.cancel();
        _timerToDetectFace = null;
        if (widget.config.allowAfterMaxSec) {
          _isCaptureButtonVisible = true;
          if (mounted) {
            setState(() {});
          }
          return;
        }
        _onDetectionCompleted(
          imgToReturn: null,
        );
      },
    );
  }

  Future<void> _takePicture({
    required bool didCaptureAutomatically,
  }) async {
    if (_cameraState == null) {
      _onDetectionCompleted();
      return;
    }
    _cameraState?.when(
      onPhotoMode: (p0) => Future.delayed(
        const Duration(milliseconds: 500),
        () => p0.takePhoto().then(
          (value) {
            _onDetectionCompleted(
              imgToReturn: value.path,
              didCaptureAutomatically: didCaptureAutomatically,
            );
          },
        ),
      ),
    );
  }

  void _onDetectionCompleted({
    String? imgToReturn,
    bool? didCaptureAutomatically,
  }) {
    if (_isCompleted) {
      return;
    }
    setState(
      () => _isCompleted = true,
    );
    final String imgPath = imgToReturn ?? "";
    if (imgPath.isEmpty || didCaptureAutomatically == null) {
      Navigator.of(context).pop(null);
      return;
    }
    Navigator.of(context).pop(
      CapturedImage(
        imgPath: imgPath,
        didCaptureAutomatically: didCaptureAutomatically,
      ),
    );
  }

  void _resetSteps() async {
    for (var p0 in _steps) {
      final int index = _steps.indexWhere(
        (p1) => p1.step == p0.step,
      );
      _steps[index] = _steps[index].copyWith(
        isCompleted: false,
      );
    }
    _didCloseEyes = false;
    if (_stepsKey.currentState?.currentIndex != 0) {
      _stepsKey.currentState?.reset();
    }
    if (mounted) {
      setState(() {});
    }
  }

  //* MARK: - Private Methods for UI Components
  //? =========================================================
  @override
  Widget build(BuildContext context) {
    return Stack(
      // fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        // buildCameraPreview(),
        // Layer di atas kamera dengan lubang berbentuk oval

        // Layer putih dengan lubang oval di atas kamera
        // Positioned.fill(
        //   child: CustomPaint(
        //     painter: OvalHolePainter(),
        //     child: Container(
        //       color: Colors.transparent,
        //     ), // Layer kosong yang akan diwarnai
        //   ),
        // ),
        Positioned.fill(
          child: Container(
            color: Colors.white, // Warna putih di seluruh layar
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: AspectRatio(
                    aspectRatio: 3/4,
                    child: Stack(
                      children: [
                        buildCameraPreview(),
                        Center(
                          child: Padding(
                            padding: EdgeInsets.all(64),
                            child: CustomPaint(
                              size: Size(160, 260), // Sesuaikan ukuran dengan layar
                              painter: OvalLinePainter(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        if (_isInfoStepCompleted)
          LivelynessDetectionStepOverlay(
            key: _stepsKey,
            steps: _steps,
            onCompleted: () => _takePicture(
              didCaptureAutomatically: true,
            ),
          ),
        Visibility(
          visible: _isCaptureButtonVisible,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Spacer(
                flex: 20,
              ),
              MaterialButton(
                onPressed: () => _takePicture(
                  didCaptureAutomatically: false,
                ),
                color: widget.config.captureButtonColor ?? Theme.of(context).primaryColor,
                textColor: Colors.white,
                padding: const EdgeInsets.all(16),
                shape: const CircleBorder(),
                child: const Icon(
                  Icons.camera_alt,
                  size: 24,
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(
              right: 10,
              top: 10,
            ),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: Colors.black,
              child: IconButton(
                onPressed: () {
                  _onDetectionCompleted(
                    imgToReturn: null,
                    didCaptureAutomatically: null,
                  );
                },
                icon: const Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  StatefulWidget buildCameraPreview() => _isInfoStepCompleted ? buildCameraAwesomeBuilder() : buildLivelynessInfoWidget();

  LivelynessInfoWidget buildLivelynessInfoWidget() {
    return LivelynessInfoWidget(
      onStartTap: () {
        if (!mounted) {
          return;
        }
        _startTimer();
        setState(
          () => _isInfoStepCompleted = true,
        );
      },
    );
  }

  CameraAwesomeBuilder buildCameraAwesomeBuilder() {
    return CameraAwesomeBuilder.custom(
      // flashMode: FlashMode.auto,
      previewFit: CameraPreviewFit.cover,
      // aspectRatio: CameraAspectRatios.ratio_16_9,
      sensorConfig: SensorConfig.single(
        aspectRatio: CameraAspectRatios.ratio_16_9,
        flashMode: FlashMode.auto,
        sensor: Sensor.position(SensorPosition.front),
      ),
      onImageForAnalysis: (img) => _processCameraImage(img),
      imageAnalysisConfig: AnalysisConfig(
        autoStart: true,
        androidOptions: const AndroidAnalysisOptions.nv21(
          width: 250,
        ),
        maxFramesPerSecond: 30,
      ),
      builder: (state, preview) {
        _cameraState = state;
        return widget.config.showFacialVertices
            ? PreviewDecoratorWidget(
                cameraState: state,
                faceDetectionStream: _faceDetectionController,
                previewSize: PreviewSize(
                  width: preview.previewSize.width,
                  height: preview.previewSize.height,
                ),
                previewRect: preview.rect,
              )
            : const SizedBox();
      },
      // (state, previewSize, previewRect) {
      //   _cameraState = state;
      //   return PreviewDecoratorWidget(
      //     cameraState: state,
      //     faceDetectionStream: _faceDetectionController,
      //     previewSize: previewSize,
      //     previewRect: previewRect,
      //     detectionColor:
      //         _steps[_stepsKey.currentState?.currentIndex ?? 0]
      //             .detectionColor,
      //   );
      // },
      saveConfig: SaveConfig.photo(
        pathBuilder: (_) async {
          final String fileName = "${Utils.generate()}.jpg";
          final String path = await getTemporaryDirectory().then(
            (value) => value.path,
          );
          // return "$path/$fileName";
          return SingleCaptureRequest(
            "$path/$fileName",
            Sensor.position(
              SensorPosition.front,
            ),
          );
        },
      ),
    );
  }

  double calculateSymmetry(Point<int>? leftPosition, Point<int>? rightPosition) {
    if (leftPosition != null && rightPosition != null) {
      final double dx = (rightPosition.x - leftPosition.x).abs().toDouble();
      final double dy = (rightPosition.y - leftPosition.y).abs().toDouble();
      final distance = Offset(dx, dy).distance;

      return distance;
    }

    return 0.0;
  }
}

class OvalLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.yellow // Warna garis oval
      ..strokeWidth = 4 // Ketebalan garis
      ..style = PaintingStyle.stroke; // Garis tepi saja (outline)

    final Rect rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2), // Posisi di tengah layar
      width: size.width, // Lebar oval 80% dari layar
      height: size.height, // Tinggi oval 40% dari layar
    );

    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false; // Tidak perlu repaint jika tidak ada perubahan
  }
}

class OvalHolePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Membuat cat untuk warna putih
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // Gambar layer putih
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);

    // Buat lubang oval
    Path ovalPath = Path()
      ..addOval(Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2), // Pusat oval
        width: 300, // Lebar oval
        height: 400, // Tinggi oval
      ));

    // Lubangi area oval pada layer putih
    canvas.clipPath(ovalPath, doAntiAlias: true);
    canvas.drawColor(Colors.transparent, BlendMode.clear);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
