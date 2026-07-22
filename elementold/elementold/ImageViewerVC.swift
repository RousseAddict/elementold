import UIKit

// Full-screen image viewer pushed from the timeline when an image bubble is
// tapped. Shows the timeline thumbnail immediately (passed in as a placeholder),
// then swaps in the full-resolution download from MediaCache when it lands.
// Pinch / double-tap to zoom via a UIScrollView; a Save button writes the
// full-res image to the device photo library.
class ImageViewerVC: UIViewController {

    private let mxc: String
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .whiteLarge)
    // The best image we currently have (placeholder until the full-res arrives) —
    // this is what "Save" writes out.
    private var currentImage: UIImage?

    init(mxc: String, placeholder: UIImage?) {
        self.mxc = mxc
        super.init(nibName: nil, bundle: nil)
        currentImage = placeholder
        imageView.image = placeholder
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Image"
        view.backgroundColor = .black

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        spinner.hidesWhenStopped = true
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                    .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save,
                                                            target: self, action: #selector(saveTapped))
        loadFull()
    }

    private func loadFull() {
        if currentImage == nil { spinner.startAnimating() }
        MediaCache.shared.loadFullImage(mxc: mxc) { [weak self] image in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            guard let image = image else { return }
            self.currentImage = image
            self.imageView.image = image
        }
    }

    @objc private func handleDoubleTap() {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            scrollView.setZoomScale(scrollView.maximumZoomScale, animated: true)
        }
    }

    @objc private func saveTapped() {
        guard let image = currentImage else { return }
        // UIImageWriteToSavedPhotosAlbum is present since iOS 2 — the completion
        // selector reports success/failure back so we can confirm to the user.
        UIImageWriteToSavedPhotosAlbum(image, self,
            #selector(saveCompleted(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func saveCompleted(_ image: UIImage, didFinishSavingWithError error: Error?,
                                     contextInfo: UnsafeRawPointer) {
        if let error = error {
            showAlert(title: "Save failed", message: "\(error)")
        } else {
            showAlert(title: "Saved", message: "Image saved to your photos.")
        }
    }

    private func showAlert(title: String, message: String) {
#if IOS6_TARGET
        let alert = UIAlertView()
        alert.title = title
        alert.message = message
        alert.addButton(withTitle: "OK")
        alert.show()
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }
}

extension ImageViewerVC: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { return imageView }
}
