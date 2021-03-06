;;; tdecl/instance.scm

;;; Convert an instance decl to a definition

;;; The treatment of instances is more complex than the treatment of other
;;; type definitions due to the possibility of derived instances.
;;; Here's the plan:
;;;  a) instance-decls are converted to instance structures.  The type
;;;     information is verified but the decls are unchanged.
;;;  b) All instances are linked into the associated classes.
;;;  c) Derived instances are generated.
;;;  d) Instance dictionaries are generated from the decls in the instances.
;;;     

;;; Instances-decl to instance definition conversion
;;; Errors detected:
;;;  Class must be a class
;;;  Data type must be an alg
;;;  Tyvars must be distinct
;;;  Correct number of tyvars
;;;  Context applies only to tyvars in simple
;;;  C-T restriction

;;; Needs work for interface files.

(define (instance->def inst-decl)
 (recover-errors '#f
  (remember-context inst-decl
    (with-slots instance-decl (context class simple decls) inst-decl
      (resolve-type simple)
      (resolve-class class)
      (let ((alg-def (tycon-def simple))
	    (class-def (class-ref-class class)))
        (when (not (algdata? (tycon-def simple)))
	  (signal-datatype-required (tycon-def simple)))
        (let ((tyvars (simple-tyvar-list simple)))
	  (resolve-signature-aux tyvars context)
	  (when (and (not (eq? *module-name* (def-module alg-def)))
		     (not (eq? *module-name* (def-module class-def))))
	    (signal-c-t-rule-violation class-def alg-def))
	  (let ((old-inst (lookup-instance alg-def class-def)))
	    (when (and (not (eq? old-inst '#f))
		       (not (instance-special? old-inst)))
	    (signal-multiple-instance class-def alg-def))
	    (let ((inst (new-instance class-def alg-def tyvars)))
	      (setf (instance-context inst) context)
	      (setf (instance-decls inst) decls)
	      (setf (instance-ok? inst) '#t)
	      inst))))))))

(define (signal-datatype-required def)
  (phase-error 'datatype-required
    "The synonym type ~a cannot be declared as an instance."
    (def-name def)))

(define (signal-c-t-rule-violation class-def alg-def)
  (phase-error 'c-t-rule-violation
    "Instance declaration does not appear in the same module as either~%~
     the class ~a or type ~a."
    class-def alg-def))

(define (signal-multiple-instance class-def alg-def)
  (phase-error 'multiple-instance
    "The type ~a has already been declared to be an instance of class ~a."
    alg-def class-def))

;;; This generates the dictionary for each instance and makes a few final
;;; integrity checks in the instance context.  This happens after derived
;;; instances are inserted.

(define (expand-instance-decls inst)
  (when (instance-ok? inst)
    (check-inst-type inst)
    (with-slots instance (class algdata dictionary decls context tyvars) inst
     (let ((simple (**tycon/def algdata (map (function **tyvar) tyvars))))
      (setf (instance-gcontext inst)
	    (gtype-context (ast->gtype/inst context simple)))
      (with-slots class (super* method-vars) class
	;; Before computing signatures uniquify tyvar names to prevent
        ;; collision with method tyvar names
	(let ((new-tyvars (map (lambda (tyvar) (tuple tyvar (gentyvar "tv")))
			       (instance-tyvars inst))))
	  (setf (instance-tyvars inst) (map (function tuple-2-2) new-tyvars))
	  (setf (instance-context inst)
   	    (map (lambda (c)
                  (**context (context-class c)
			     (tuple-2-2 (assq (context-tyvar c) new-tyvars))))
		 (instance-context inst))))
	;; Now walk over the decls & rename each method with a unique name
	;; generated by combining the class, type, and method.  Watch for
	;; multiple defs of methods and add defaults after all decls have
	;; been scanned.
	(let ((methods-used '())
	      (new-instance-vars (map (lambda (m)
					(tuple m (method-def-var m inst)))
				      method-vars)))
          (dolist (decl decls)
            (setf methods-used
  	      (process-instance-decl decl new-instance-vars methods-used)))
	  ;; now add defaults when needed
	  (dolist (m-v new-instance-vars)
           (let* ((method-var (tuple-2-1 m-v))
		  (definition-var (tuple-2-2 m-v))
		  (signature (generate-method-signature inst method-var '#t)))
            (if (memq method-var methods-used)
		(add-new-module-signature definition-var signature)
		(let ((method-body
		       (if (eq? (method-var-default method-var) '#f)
			   (**abort (format '#f
     "No method declared for method ~A in instance ~A(~A)."
                              method-var class algdata))
			   (**var/def (method-var-default method-var)))))
		  (add-new-module-def definition-var method-body)
		  (add-new-module-signature definition-var signature)))))
	  (setf (instance-methods inst) new-instance-vars)
	  (add-new-module-def dictionary
	     (**tuple/l (append (map (lambda (m-v)
				       (dict-method-ref
					(tuple-2-1 m-v)	(tuple-2-2 m-v)	inst))
				     new-instance-vars)
				(map (lambda (c)
				       (get-class-dict algdata c))
				     super*))))
	  (let ((dict-sig (generate-dictionary-signature inst)))
	    (add-new-module-signature dictionary dict-sig))
	  (setf (instance-decls inst) '())))))))

(define (dict-method-ref method-var inst-var inst)
  (if (null? (signature-context (method-var-method-signature method-var)))
      (**var/def inst-var)
      (let* ((sig (generate-method-signature inst method-var '#f))
	     (ctxt (signature-context sig))
	     (ty (signature-type sig)))
	(make overloaded-var-ref
	      (sig (ast->gtype ctxt ty))
	      (var inst-var)))))

(define (get-class-dict algdata class)
  (let ((inst (lookup-instance algdata class)))
    (if (eq? inst '#f)
	(**abort "Missing super class")
	(**var/def (instance-dictionary inst)))))
					 
(define (process-instance-decl decl new-instance-vars methods-used)
  (if (valdef? decl)
      (rename-instance-decl decl new-instance-vars methods-used)
      (begin
       (dolist (a (annotation-decls-annotations decl))
	(cond ((annotation-value? a)
	       (recoverable-error 'misplaced-annotation
		      "Misplaced annotation: ~A~%" a))
	      (else
	       (dolist (name (annotation-decl-names a))
                 (attach-method-annotation
		  name (annotation-decl-annotations a) new-instance-vars)))))
       methods-used)))

(define (attach-method-annotation name annotations vars)
  (cond ((null? vars)
	 (signal-no-method name))
	((eq? name (def-name (tuple-2-1 (car vars))))
	 (setf (var-annotations (tuple-2-2 (car vars)))
	       (append annotations (var-annotations (tuple-2-2 (car vars))))))
	(else (attach-method-annotation name annotations (cdr vars)))))

(define (signal-no-method name)
  (recoverable-error 'no-method "~A is not a method in this class.~%"
      name))

(define (rename-instance-decl decl new-instance-vars methods-used)
  (let ((decl-vars (collect-pattern-vars (valdef-lhs decl))))
    (dolist (var decl-vars)
      (resolve-var var)
      (let ((method (var-ref-var var)))
        (when (not (eq? method *undefined-def*))
         (let ((m-v (assq method new-instance-vars)))
          (cond ((memq method methods-used)
		 (signal-multiple-instance-def method))
		((eq? m-v '#f)
		 (signal-not-in-class method))
		(else
		 (setf (var-ref-name var) (def-name (tuple-2-2 m-v)))
		 (setf (var-ref-var var) (tuple-2-2 m-v))
		 (push (tuple-2-1 m-v) methods-used)))))))
    (add-new-module-decl decl)
    methods-used))

(define (signal-multiple-instance-def method)
  (phase-error 'multiple-instance-def
    "The instance declaration has multiple definitions of the method ~a."
     method))

(define (signal-not-in-class method)
  (phase-error 'not-in-class
    "The instance declaration includes a definition for ~a,~%~
     which is not one of the methods for this class."
    method))


(define (method-def-var method-var inst)
  (make-new-var
    (string-append "i-"
		   (symbol->string (print-name (instance-class inst))) "-"
		   (symbol->string (print-name (instance-algdata inst))) "-"
		   (symbol->string (def-name method-var)))))

(define (generate-method-signature inst method-var keep-method-context?)
  (let* ((simple-type (make-instance-type inst))
	 (class-context (instance-context inst))
	 (class-tyvar (class-tyvar (instance-class inst)))
	 (signature (method-var-method-signature method-var)))
    (make signature
	  (context (if keep-method-context?
		       (append class-context (signature-context signature))
		       class-context))
	  (type (substitute-tyvar (signature-type signature) class-tyvar
				  simple-type)))))

(define (make-instance-type inst)
  (**tycon/def (instance-algdata inst)
	       (map (function **tyvar) (instance-tyvars inst))))

(define (generate-dictionary-signature inst)
  (**signature (sort-inst-context-by-tyvar
		(instance-context inst) (instance-tyvars inst))
	       (generate-dictionary-type inst (make-instance-type inst))))

(define (sort-inst-context-by-tyvar ctxt tyvars)
  (concat (map (lambda (tyvar)
		 (extract-single-context tyvar ctxt)) tyvars)))

(define (extract-single-context tyvar ctxt)
  (if (null? ctxt)
      '()
      (let ((rest (extract-single-context tyvar (cdr ctxt))))
	(if (eq? tyvar (context-tyvar (car ctxt)))
	    (cons (car ctxt) rest)
	    rest))))

(define (generate-dictionary-type inst simple)
  (let* ((class (instance-class inst))
	 (algdata (instance-algdata inst))
	 (tyvar (class-tyvar class)))
    (**tuple-type/l (append (map (lambda (method-var)
				   ;; This ignores the context associated
				   ;; with a method
				   (let ((sig (method-var-method-signature
					        method-var)))
				     (substitute-tyvar (signature-type sig)
						       tyvar
						       simple)))
				 (class-method-vars class))
			    (map (lambda (super-class)
				   (generate-dictionary-type
				    (lookup-instance algdata super-class)
				    simple))
				 (class-super* class))))))

;;; Checks performed here:
;;;  Instance context must include the following:
;;;     Context associated with data type
;;;     Context associated with instances for each super class
;;;  All super class instances must exist

(define (check-inst-type inst)
   (let* ((class (instance-class inst))
	  (algdata (instance-algdata inst))
	  (inst-context (instance-gcontext inst))
	  (alg-context (gtype-context (algdata-signature algdata))))
     (when (not (full-context-implies? inst-context alg-context))
       (signal-instance-context-needs-alg-context algdata))
     (dolist (super-c (class-super class))
       (let ((super-inst (lookup-instance algdata super-c)))
	 (cond ((eq? super-inst '#f)
		(signal-no-super-class-instance class algdata super-c))
	       (else
		(when (not (full-context-implies?
			     inst-context (instance-context super-inst)))
		  (signal-instance-context-insufficient-for-super
		    class algdata super-c))))))
     ))

(define (signal-instance-context-needs-alg-context algdata)
  (phase-error 'instance-context-needs-alg-context
    "The instance context needs to include context defined for data type ~A."
    algdata))

(define (signal-no-super-class-instance class algdata super-c)
  (fatal-error 'no-super-class-instance
    "The instance ~A(~A) requires that the instance ~A(~A) be provided."
    class algdata super-c algdata))

(define (signal-instance-context-insufficient-for-super class algdata super-c)
  (phase-error 'instance-context-insufficient-for-super
    "Instance ~A(~A) does not imply super class ~A instance context."
    class algdata super-c))
